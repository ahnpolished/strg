import json
import re
from pathlib import Path

import torch
from common.schema import WorkoutPage
from PIL import Image
from transformers import AutoProcessor, Qwen2VLForConditionalGeneration

from models_server.base import ServerModelRunner
from models_server.prompt import EXTRACTION_PROMPT


def _normalize_entries(data: dict) -> dict:
    """Normalize model output quirks before Pydantic validation."""
    entries = data.get("entries", [])
    for entry in entries:
        # --- date normalization ---
        date_val = entry.get("date")
        if isinstance(date_val, str):
            d = date_val.strip()
            # YYYY/MM/DD → YYYY-MM-DD
            m = re.match(r"^(\d{4})/(\d{1,2})/(\d{1,2})$", d)
            if m:
                entry["date"] = f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
                d = entry["date"]
            # DD/MM/YYYY → YYYY-MM-DD (European format — treat as DD/MM)
            m = re.match(r"^(\d{1,2})/(\d{1,2})/(\d{4})$", d)
            if m:
                entry["date"] = f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
                d = entry["date"]
            # DD-MM-YYYY → YYYY-MM-DD (only when year is last 4-digit group)
            m = re.match(r"^(\d{1,2})-(\d{1,2})-(\d{4})$", d)
            if m:
                entry["date"] = f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"

        # --- scalar coercion: reps and sets may come as lists ---
        for field in ("reps", "sets"):
            val = entry.get(field)
            if isinstance(val, list) and val:
                entry[field] = val[0]

        # --- weight fields: coerce list→scalar, then non-numeric→null ---
        for field in ("weight_kg", "weight_lbs"):
            val = entry.get(field)
            if isinstance(val, list) and val:
                val = val[0]
            if val is not None:
                try:
                    entry[field] = float(val)
                except (ValueError, TypeError):
                    entry[field] = None

        # --- default sets=1 when entry has reps/weight but no explicit sets ---
        if entry.get("sets") is None and (
            entry.get("reps") is not None
            or entry.get("weight_kg") is not None
            or entry.get("weight_lbs") is not None
        ):
            entry["sets"] = 1

        # --- resolve weight_kg + weight_lbs both set (model confusion) ---
        # If weight_lbs ≈ weight_kg * 2.2, model put the lbs value in weight_kg
        # and then auto-computed weight_lbs. Correct to weight_lbs=weight_kg, clear weight_kg.
        # Otherwise (unrelated values), prefer weight_lbs and clear weight_kg.
        wkg = entry.get("weight_kg")
        wlbs = entry.get("weight_lbs")
        if wkg is not None and wlbs is not None:
            if abs(wlbs - wkg * 2.2046) < 0.06 * wkg:
                # Detected kg→lbs auto-conversion: the real lbs value is weight_kg
                entry["weight_lbs"] = wkg
                entry["weight_kg"] = None
            else:
                # Unknown conflict — prefer weight_lbs, clear weight_kg
                entry["weight_kg"] = None

        # --- strip brackets from notes: model wraps notes as "[PR!]" → "PR!" ---
        notes_val = entry.get("notes")
        if isinstance(notes_val, str):
            entry["notes"] = re.sub(r"^\[(.+)\]$", r"\1", notes_val.strip())

    return data


def _extract_json(text: str) -> dict:
    """Extract JSON object from model output, handling markdown code blocks and truncation."""
    text = text.strip()
    # Strip markdown code fences (```json ... ``` or ``` ... ```)
    fence_match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if fence_match:
        text = fence_match.group(1)
    # Find outermost { ... } in case there's preamble/postamble
    brace_start = text.find("{")
    brace_end = text.rfind("}")
    if brace_start != -1 and brace_end > brace_start:
        text = text[brace_start : brace_end + 1]
    # Try direct parse first
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        # Recovery: truncated JSON — remove last incomplete entry object, close the list+dict
        # Look for the last complete entry: "    }" followed by end of valid content
        last_entry = text.rfind("\n    }")
        if last_entry != -1:
            truncated = text[: last_entry + 6] + "\n  ]\n}"
            try:
                return json.loads(truncated)
            except json.JSONDecodeError:
                pass
        raise exc


class Qwen2VLRunner(ServerModelRunner):
    model_id = "Qwen/Qwen2-VL-7B-Instruct"

    def load(self) -> None:
        self._processor = AutoProcessor.from_pretrained(self.model_id)
        self._model = Qwen2VLForConditionalGeneration.from_pretrained(
            self.model_id,
            torch_dtype=torch.bfloat16,
            device_map="auto",
        )

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "image", "image": image},
                    {"type": "text", "text": EXTRACTION_PROMPT},
                ],
            }
        ]
        text = self._processor.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        inputs = self._processor(text=[text], images=[image], return_tensors="pt").to(
            self._model.device
        )
        with torch.no_grad():
            output_ids = self._model.generate(**inputs, max_new_tokens=2048)
        generated = self._processor.batch_decode(
            output_ids[:, inputs["input_ids"].shape[1] :],
            skip_special_tokens=True,
        )[0]
        print(f"[DEBUG] raw output: {generated[:200]!r}")
        data = _extract_json(generated)
        data = _normalize_entries(data)
        return WorkoutPage.model_validate(data)
