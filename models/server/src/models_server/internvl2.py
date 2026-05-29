from pathlib import Path

import torch
from common.schema import WorkoutPage
from PIL import Image
from transformers import AutoModel, AutoTokenizer

from models_server.base import ServerModelRunner
from models_server.prompt import EXTRACTION_PROMPT

IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)
INTERNVL_IMAGE_SIZE = 448
INTERNVL_MAX_TILES = 6


def _pil_to_normalized_tensor(
    image: Image.Image,
    *,
    device: torch.device | str,
    dtype: torch.dtype,
) -> torch.Tensor:
    """Convert a 448x448 RGB PIL tile to InternVL's normalized tensor format."""
    byte_tensor = torch.frombuffer(bytearray(image.tobytes()), dtype=torch.uint8)
    tensor = (
        byte_tensor.reshape(INTERNVL_IMAGE_SIZE, INTERNVL_IMAGE_SIZE, 3)
        .permute(2, 0, 1)
        .to(torch.float32)
        / 255.0
    )
    mean = torch.tensor(IMAGENET_MEAN, dtype=torch.float32).view(3, 1, 1)
    std = torch.tensor(IMAGENET_STD, dtype=torch.float32).view(3, 1, 1)
    return ((tensor - mean) / std).to(device=device, dtype=dtype)


def _choose_tile_grid(
    width: int, height: int, max_tiles: int = INTERNVL_MAX_TILES
) -> tuple[int, int]:
    """Choose an InternVL-style tile grid that best preserves page aspect ratio."""
    aspect_ratio = width / height
    candidates = [
        (cols, rows)
        for tiles in range(1, max_tiles + 1)
        for cols in range(1, tiles + 1)
        for rows in range(1, tiles + 1)
        if 1 <= cols * rows <= max_tiles
    ]
    return min(candidates, key=lambda grid: abs((grid[0] / grid[1]) - aspect_ratio))


def _preprocess_image(
    image: Image.Image,
    *,
    device: torch.device | str,
    dtype: torch.dtype = torch.bfloat16,
    max_tiles: int = INTERNVL_MAX_TILES,
) -> torch.Tensor:
    """Preprocess a page for InternVL2 using dynamic tiling without torchvision.

    InternVL2 is trained to consume one or more 448px image tiles. Resizing a full
    workout page to a single 448x448 square makes handwritten rows too small and
    distorted, so we preserve aspect ratio by splitting the page into a small
    grid of 448px tiles. A thumbnail tile is appended when multiple tiles are
    used, matching common InternVL inference practice while keeping 24GB GPUs in
    mind via a conservative tile cap.
    """
    image = image.convert("RGB")
    width, height = image.size
    cols, rows = _choose_tile_grid(width, height, max_tiles=max_tiles)
    resized = image.resize(
        (cols * INTERNVL_IMAGE_SIZE, rows * INTERNVL_IMAGE_SIZE),
        Image.Resampling.BICUBIC,
    )

    tiles: list[Image.Image] = []
    for row in range(rows):
        for col in range(cols):
            left = col * INTERNVL_IMAGE_SIZE
            upper = row * INTERNVL_IMAGE_SIZE
            tiles.append(
                resized.crop(
                    (
                        left,
                        upper,
                        left + INTERNVL_IMAGE_SIZE,
                        upper + INTERNVL_IMAGE_SIZE,
                    )
                )
            )

    if len(tiles) > 1:
        tiles.append(
            image.resize((INTERNVL_IMAGE_SIZE, INTERNVL_IMAGE_SIZE), Image.Resampling.BICUBIC)
        )

    tensors = [_pil_to_normalized_tensor(tile, device=device, dtype=dtype) for tile in tiles]
    return torch.stack(tensors)


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
        image = Image.open(image_path).convert("RGB")
        pixel_values = _preprocess_image(
            image,
            device=self._model.device,
            dtype=torch.bfloat16,
        )

        generation_config = {"max_new_tokens": 2048, "do_sample": False}
        response = self._model.chat(
            self._tokenizer,
            pixel_values,
            f"<image>\n{EXTRACTION_PROMPT}",
            generation_config,
            num_patches_list=[pixel_values.size(0)],
        )
        print(f"[DEBUG] raw output: {response[:200]!r}")
        from models_server.qwen2_vl import _extract_json, _normalize_entries

        data = _extract_json(response)
        data = _normalize_entries(data)
        return WorkoutPage.model_validate(data)
