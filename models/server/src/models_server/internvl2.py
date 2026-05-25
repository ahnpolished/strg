import json
from pathlib import Path

import torch
from common.schema import WorkoutPage
from PIL import Image
from transformers import AutoModel, AutoTokenizer

from models_server.base import ServerModelRunner
from models_server.prompt import EXTRACTION_PROMPT

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


class InternVL2Runner(ServerModelRunner):
    model_id = "OpenGVLab/InternVL2-8B"

    def load(self) -> None:
        self._tokenizer = AutoTokenizer.from_pretrained(self.model_id, trust_remote_code=True)
        self._model = AutoModel.from_pretrained(
            self.model_id,
            torch_dtype=torch.bfloat16,
            device_map="auto",
            trust_remote_code=True,
        ).eval()

    def predict(self, image_path: Path) -> WorkoutPage:
        import torchvision.transforms as T
        from torchvision.transforms.functional import InterpolationMode

        transform = T.Compose(
            [
                T.Resize((448, 448), interpolation=InterpolationMode.BICUBIC),
                T.ToTensor(),
                T.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD),
            ]
        )
        image = Image.open(image_path).convert("RGB")
        pixel_values = transform(image).unsqueeze(0).to(torch.bfloat16).to(self._model.device)

        generation_config = {"max_new_tokens": 1024, "do_sample": False}
        response = self._model.chat(
            self._tokenizer,
            pixel_values,
            EXTRACTION_PROMPT,
            generation_config,
        )
        return WorkoutPage.model_validate(json.loads(response.strip()))
