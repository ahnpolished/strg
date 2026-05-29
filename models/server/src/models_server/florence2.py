from pathlib import Path

import torch
from common.schema import WorkoutPage
from PIL import Image
from transformers import AutoModelForCausalLM, AutoProcessor

from models_server.base import ServerModelRunner

# Florence-2 uses a fixed task token format — OCR then parse
_OCR_TASK = "<OCR>"


class Florence2Runner(ServerModelRunner):
    model_id = "microsoft/florence-2-large"

    def load(self) -> None:
        self._processor = AutoProcessor.from_pretrained(self.model_id, trust_remote_code=True)
        device = "cuda" if torch.cuda.is_available() else "cpu"
        self._model = (
            AutoModelForCausalLM.from_pretrained(
                self.model_id,
                torch_dtype=torch.float16,
                trust_remote_code=True,
                attn_implementation="eager",
            )
            .to(device)
            .eval()
        )

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        inputs = self._processor(text=_OCR_TASK, images=image, return_tensors="pt")

        print(f"DEBUG: inputs keys: {list(inputs.keys())}")
        for k, v in inputs.items():
            if torch.is_tensor(v):
                print(f"DEBUG: inputs[{k}] shape: {v.shape}, dtype: {v.dtype}")

        print(f"DEBUG: model device: {self._model.device}")

        inputs = inputs.to(self._model.device, torch.float16)

        for k, v in inputs.items():
            if torch.is_tensor(v):
                print(
                    f"DEBUG: moved inputs[{k}] shape: {v.shape}, dtype: {v.dtype}, device: {v.device}"  # noqa: E501
                )

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
    weight_pat = re.compile(r"(?<!\d)(\d+(?:\.\d+)?)[.,]*\s*(kg|lbs?)\b", re.IGNORECASE)
    sets_reps_pat = re.compile(r"(\d+)\s*(?:[xX×]|sets?\s*(?:of|x)?\s*)\s*(\d+)")
    reps_pat = re.compile(r"(?:^|\s)(?:x|×|reps?\s*)\s*(\d+)(?:\s|$)", re.IGNORECASE)

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
        reps_match = reps_pat.search(line)
        wm = weight_pat.search(line)

        # Avoid turning arbitrary OCR fragments into workout entries. A useful
        # row should contain at least a rep/set pattern or a weight token.
        if not (sr_match or reps_match or wm):
            continue

        exercise = sets_reps_pat.sub("", line)
        exercise = reps_pat.sub(" ", exercise)
        exercise = weight_pat.sub("", exercise).strip(" -:,.•|[]()")

        if not exercise:
            continue

        sets = int(sr_match.group(1)) if sr_match else 1
        reps = (
            int(sr_match.group(2))
            if sr_match
            else (int(reps_match.group(1)) if reps_match else None)
        )
        weight_kg = None
        weight_lbs = None
        if wm:
            try:
                val = float(wm.group(1).rstrip("."))
            except ValueError:
                continue
            if wm.group(2).lower().startswith("lb"):
                weight_lbs = val
            else:
                weight_kg = val

        entries.append(
            WorkoutEntry(
                date=date,
                exercise=exercise,
                sets=sets,
                reps=reps,
                weight_kg=weight_kg,
                weight_lbs=weight_lbs,
            )
        )

    return WorkoutPage(entries=entries)
