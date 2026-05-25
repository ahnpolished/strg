import json
from pathlib import Path

import torch
from PIL import Image
from transformers import AutoModel, AutoTokenizer

from common.schema import WorkoutPage
from models_local.base import LocalModelRunner
from models_local.prompt import EXTRACTION_PROMPT


class MiniCPMRunner(LocalModelRunner):
    model_id = "openbmb/MiniCPM-V-2_6"

    def load(self) -> None:
        self._tokenizer = AutoTokenizer.from_pretrained(
            self.model_id, trust_remote_code=True
        )
        self._model = AutoModel.from_pretrained(
            self.model_id,
            trust_remote_code=True,
            attn_implementation="sdpa",
            torch_dtype=torch.bfloat16,
        ).eval()
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        self._model = self._model.to(device)

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        msgs = [{"role": "user", "content": [image, EXTRACTION_PROMPT]}]
        response = self._model.chat(
            image=None,
            msgs=msgs,
            tokenizer=self._tokenizer,
            sampling=False,
            max_new_tokens=1024,
        )
        return WorkoutPage.model_validate(json.loads(response.strip()))
