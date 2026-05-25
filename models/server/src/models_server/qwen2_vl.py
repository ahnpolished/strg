import json
from pathlib import Path

import torch
from PIL import Image
from transformers import AutoProcessor, Qwen2VLForConditionalGeneration

from common.schema import WorkoutPage
from models_server.base import ServerModelRunner
from models_server.prompt import EXTRACTION_PROMPT


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
            output_ids = self._model.generate(**inputs, max_new_tokens=1024)
        generated = self._processor.batch_decode(
            output_ids[:, inputs["input_ids"].shape[1]:],
            skip_special_tokens=True,
        )[0]
        return WorkoutPage.model_validate(json.loads(generated.strip()))
