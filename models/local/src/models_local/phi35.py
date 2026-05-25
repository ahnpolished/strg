import json
from pathlib import Path

import torch
from PIL import Image
from transformers import AutoModelForCausalLM, AutoProcessor

from common.schema import WorkoutPage
from models_local.base import LocalModelRunner
from models_local.prompt import EXTRACTION_PROMPT


class Phi35VisionRunner(LocalModelRunner):
    model_id = "microsoft/Phi-3.5-vision-instruct"

    def load(self) -> None:
        self._processor = AutoProcessor.from_pretrained(
            self.model_id, trust_remote_code=True, num_crops=4
        )
        self._model = AutoModelForCausalLM.from_pretrained(
            self.model_id,
            device_map="cpu",
            trust_remote_code=True,
            torch_dtype=torch.float32,
            _attn_implementation="eager",
        ).eval()

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        messages = [
            {"role": "user", "content": "<|image_1|>\n" + EXTRACTION_PROMPT}
        ]
        prompt = self._processor.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        inputs = self._processor(prompt, [image], return_tensors="pt")
        with torch.no_grad():
            output_ids = self._model.generate(
                **inputs,
                max_new_tokens=1024,
                eos_token_id=self._processor.tokenizer.eos_token_id,
            )
        generated = self._processor.batch_decode(
            output_ids[:, inputs["input_ids"].shape[1]:],
            skip_special_tokens=True,
        )[0]
        return WorkoutPage.model_validate(json.loads(generated.strip()))
