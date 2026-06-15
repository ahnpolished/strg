"""Phi-3.5-Vision server runner with QLoRA support.

3.8B params — best accuracy/speed trade-off for L4 GPU.
Eval results: CER 0.065, Field Acc 0.865.

On L4 (24 GB): ~20-35 s per inference (vs Qwen2-VL-7B at ~130 s).
"""

import json
import os
from pathlib import Path

import torch
from common.schema import WorkoutPage
from PIL import Image
from transformers import AutoModelForCausalLM, AutoProcessor

from models_server.base import ServerModelRunner
from models_server.prompt import EXTRACTION_PROMPT
from models_server.qwen2_vl import _normalize_entries

MODEL_ID = "microsoft/Phi-3.5-vision-instruct"


class Phi35VLRunner(ServerModelRunner):
    model_id = MODEL_ID

    def load(self) -> None:
        model_path = os.environ.get("STRG_PHI35_MODEL_PATH", self.model_id)
        lora_checkpoint = os.environ.get("STRG_PHI35_LORA_CHECKPOINT", "")

        self._processor = AutoProcessor.from_pretrained(
            model_path,
            trust_remote_code=True,
            num_crops=4,
        )

        load_in_4bit = os.environ.get("STRG_PHI35_LOAD_IN_4BIT", "1").lower() in (
            "1",
            "true",
            "yes",
        )

        model_kwargs: dict = {
            "trust_remote_code": True,
            "torch_dtype": torch.bfloat16 if torch.cuda.is_available() else torch.float32,
            "device_map": "auto" if torch.cuda.is_available() else None,
            "_attn_implementation": "eager",
        }

        if load_in_4bit and torch.cuda.is_available():
            from transformers import BitsAndBytesConfig

            model_kwargs["quantization_config"] = BitsAndBytesConfig(
                load_in_4bit=True,
                bnb_4bit_compute_dtype=torch.bfloat16,
                bnb_4bit_use_double_quant=True,
                bnb_4bit_quant_type="nf4",
            )

        base = AutoModelForCausalLM.from_pretrained(model_path, **model_kwargs)

        if lora_checkpoint:
            from peft import PeftModel

            print(f"[phi35] Loading LoRA adapter from {lora_checkpoint}")
            self._model = PeftModel.from_pretrained(base, lora_checkpoint)
        else:
            self._model = base

        self._model.eval()
        print(f"[phi35] Model loaded on {self._model.device}")

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        messages = [{"role": "user", "content": "<|image_1|>\n" + EXTRACTION_PROMPT}]
        prompt = self._processor.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        inputs = self._processor(prompt, [image], return_tensors="pt")
        inputs = {k: v.to(self._model.device) for k, v in inputs.items()}

        with torch.no_grad():
            output_ids = self._model.generate(
                **inputs,
                max_new_tokens=1024,
                do_sample=False,
                eos_token_id=self._processor.tokenizer.eos_token_id,
            )

        generated = self._processor.batch_decode(
            output_ids[:, inputs["input_ids"].shape[1] :],
            skip_special_tokens=True,
        )[0]

        print(f"[phi35] raw output: {generated[:200]!r}")
        data = json.loads(generated.strip())
        data = _normalize_entries(data)
        return WorkoutPage.model_validate(data)
