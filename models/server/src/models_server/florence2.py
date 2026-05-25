import json
from pathlib import Path

import torch
from PIL import Image
from transformers import AutoModelForCausalLM, AutoProcessor

from common.schema import WorkoutPage
from models_server.base import ServerModelRunner

# Florence-2 uses a fixed task token format — OCR then parse
_OCR_TASK = "<OCR>"


class Florence2Runner(ServerModelRunner):
    model_id = "microsoft/florence-2-large"

    def load(self) -> None:
        self._processor = AutoProcessor.from_pretrained(
            self.model_id, trust_remote_code=True
        )
        self._model = AutoModelForCausalLM.from_pretrained(
            self.model_id,
            torch_dtype=torch.float16,
            device_map="auto",
            trust_remote_code=True,
        ).eval()

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        inputs = self._processor(
            text=_OCR_TASK, images=image, return_tensors="pt"
        ).to(self._model.device, torch.float16)

        with torch.no_grad():
            output_ids = self._model.generate(
                **inputs,
                max_new_tokens=2048,
                num_beams=3,
            )
        raw_text = self._processor.batch_decode(output_ids, skip_special_tokens=False)[0]
        parsed = self._processor.post_process_generation(
            raw_text, task=_OCR_TASK, image_size=(image.width, image.height)
        )
        ocr_text = parsed.get(_OCR_TASK, "")

        # Florence-2 returns raw OCR text — use a structured parse pass
        return _parse_ocr_text_to_page(ocr_text)


def _parse_ocr_text_to_page(text: str) -> WorkoutPage:
    """Best-effort heuristic parser for Florence-2 OCR output."""
    import datetime
    import re

    from common.schema import WorkoutEntry

    entries = []
    date = None
    date_pat = re.compile(r"(\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{2,4})")
    weight_pat = re.compile(r"([\d.]+)\s*(kg|lbs?)", re.IGNORECASE)
    sets_reps_pat = re.compile(r"(\d+)\s*[xX×]\s*(\d+)")

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        dm = date_pat.search(line)
        if dm:
            try:
                date = datetime.date.fromisoformat(dm.group(0).replace("/", "-"))
                continue
            except ValueError:
                pass

        sr_match = sets_reps_pat.search(line)
        wm = weight_pat.search(line)
        exercise = sets_reps_pat.sub("", line)
        exercise = weight_pat.sub("", exercise).strip(" -:,")

        if not exercise:
            continue

        sets = int(sr_match.group(1)) if sr_match else None
        reps = int(sr_match.group(2)) if sr_match else None
        weight_kg = None
        if wm:
            val = float(wm.group(1))
            weight_kg = val * 0.4536 if wm.group(2).lower().startswith("lb") else val

        entries.append(
            WorkoutEntry(
                date=date or datetime.date.today(),
                exercise=exercise,
                sets=sets,
                reps=reps,
                weight_kg=weight_kg,
            )
        )

    return WorkoutPage(entries=entries)
