import json
from pathlib import Path

import torch
from common.schema import WorkoutPage
from PIL import Image
from transformers import AutoModelForCausalLM, AutoTokenizer

from models_local.base import LocalModelRunner
from models_local.prompt import EXTRACTION_PROMPT


class MoondreamRunner(LocalModelRunner):
    model_id = "vikhyatk/moondream2"
    revision = "2025-01-09"

    def load(self) -> None:
        self._tokenizer = AutoTokenizer.from_pretrained(self.model_id, revision=self.revision)
        self._model = AutoModelForCausalLM.from_pretrained(
            self.model_id,
            trust_remote_code=True,
            revision=self.revision,
            torch_dtype=torch.float32,
        ).eval()
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        self._model = self._model.to(device)

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        enc_image = self._model.encode_image(image)
        answer = self._model.answer_question(enc_image, EXTRACTION_PROMPT, self._tokenizer)
        return WorkoutPage.model_validate(json.loads(answer.strip()))
