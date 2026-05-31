import json
from pathlib import Path

import torch
from PIL import Image

try:
    from transformers import AutoModelForVision2Seq
except ImportError:
    from transformers import AutoModelForCausalLM as AutoModelForVision2Seq  # transformers ≥5.x
from common.schema import WorkoutPage
from transformers import AutoProcessor

from models_local.base import LocalModelRunner
from models_local.prompt import EXTRACTION_PROMPT


class SmolVLMRunner(LocalModelRunner):
    model_id = "HuggingFaceTB/SmolVLM-500M-Instruct"

    def load(self) -> None:
        self._processor = AutoProcessor.from_pretrained(self.model_id)
        self._model = AutoModelForVision2Seq.from_pretrained(
            self.model_id,
            torch_dtype=torch.bfloat16,
        ).eval()
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        self._model = self._model.to(device)

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "image"},
                    {"type": "text", "text": EXTRACTION_PROMPT},
                ],
            }
        ]
        prompt = self._processor.apply_chat_template(messages, add_generation_prompt=True)
        inputs = self._processor(text=prompt, images=[image], return_tensors="pt").to(
            self._model.device
        )
        with torch.no_grad():
            output_ids = self._model.generate(**inputs, max_new_tokens=1024)
        generated = self._processor.batch_decode(
            output_ids[:, inputs["input_ids"].shape[1] :],
            skip_special_tokens=True,
        )[0]
        return WorkoutPage.model_validate(json.loads(generated.strip()))
