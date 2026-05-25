"""
Donut zero-shot runner using DocVQA task to extract structured workout data.
Fine-tuned performance will be significantly better than zero-shot.
"""
import json
import re
from pathlib import Path

import torch
from PIL import Image
from transformers import DonutProcessor, VisionEncoderDecoderModel

from common.schema import WorkoutPage
from models_server.base import ServerModelRunner

_MODEL_ID = "naver-clova-ix/donut-base-finetuned-docvqa"
_TASK_PROMPT = "<s_docvqa><s_question>{}</s_question><s_answer>"
_QUESTION = (
    "Extract all workout entries as JSON with fields: date, exercise, sets, reps, weight_kg, notes. "
    "Return only valid JSON with an 'entries' array."
)


class DonutRunner(ServerModelRunner):
    model_id = _MODEL_ID

    def load(self) -> None:
        self._processor = DonutProcessor.from_pretrained(self.model_id)
        self._model = VisionEncoderDecoderModel.from_pretrained(
            self.model_id,
            torch_dtype=torch.float16,
        ).to("cuda" if torch.cuda.is_available() else "cpu")
        self._model.eval()

    def predict(self, image_path: Path) -> WorkoutPage:
        image = Image.open(image_path).convert("RGB")
        decoder_input = self._processor.tokenizer(
            _TASK_PROMPT.format(_QUESTION),
            add_special_tokens=False,
            return_tensors="pt",
        ).input_ids
        pixel_values = self._processor(image, return_tensors="pt").pixel_values.to(
            self._model.device, torch.float16
        )
        with torch.no_grad():
            outputs = self._model.generate(
                pixel_values,
                decoder_input_ids=decoder_input.to(self._model.device),
                max_length=self._model.decoder.config.max_position_embeddings,
                early_stopping=True,
                pad_token_id=self._processor.tokenizer.pad_token_id,
                eos_token_id=self._processor.tokenizer.eos_token_id,
                use_cache=True,
                num_beams=1,
                bad_words_ids=[[self._processor.tokenizer.unk_token_id]],
                return_dict_in_generate=True,
            )
        sequence = self._processor.batch_decode(outputs.sequences)[0]
        sequence = sequence.replace(self._processor.tokenizer.eos_token, "").replace(
            self._processor.tokenizer.pad_token, ""
        )
        sequence = re.sub(r"<.*?>", "", sequence).strip()
        return WorkoutPage.model_validate(json.loads(sequence))
