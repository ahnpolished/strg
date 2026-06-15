"""Moondream2 server runner — fast inference on GPU.

1.8B params — targets ~3-8 s per inference on L4 GPU.
Sacrifices some accuracy (CER 0.160, Field Acc 0.72) for speed.
Accuracy improves iteratively via the feedback → fine-tune loop.

On L4 (24 GB): ~3-8 s per inference.
"""

import json
from pathlib import Path

import torch
from common.schema import WorkoutPage
from PIL import Image
from transformers import AutoModelForCausalLM, AutoTokenizer

from models_server.base import ServerModelRunner
from models_server.prompt import EXTRACTION_PROMPT

MODEL_ID = "vikhyatk/moondream2"
MODEL_REVISION = "2025-01-09"


class MoondreamServerRunner(ServerModelRunner):
    model_id = MODEL_ID

    def load(self) -> None:
        self._tokenizer = AutoTokenizer.from_pretrained(self.model_id, revision=MODEL_REVISION)
        torch_dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32

        self._model = AutoModelForCausalLM.from_pretrained(
            self.model_id,
            trust_remote_code=True,
            revision=MODEL_REVISION,
            torch_dtype=torch_dtype,
        )

        device = "cuda" if torch.cuda.is_available() else "cpu"
        self._model = self._model.to(device).eval()
        print(f"[moondream] Model loaded on {device}")

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        enc_image = self._model.encode_image(image)
        answer = self._model.answer_question(enc_image, EXTRACTION_PROMPT, self._tokenizer)

        print(f"[moondream] raw output: {answer[:200]!r}")

        # Moondream sometimes wraps JSON in markdown or adds explanatory text
        text = answer.strip()
        # Strip markdown fences
        if text.startswith("```"):
            lines = text.split("\n")
            text = "\n".join(line for line in lines if not line.startswith("```")).strip()

        data = json.loads(text)
        return WorkoutPage.model_validate(data)
