"""Moondream2 server runner — fast inference on GPU.

1.8B params — targets ~3-8 s per inference on L4 GPU.
Sacrifices some accuracy (CER 0.160, Field Acc 0.72) for speed.
Accuracy improves iteratively via the feedback → fine-tune loop.

On L4 (24 GB): ~3-8 s per inference.

Note: pyvips is required by moondream's image_crops.py for multi-crop
tiling, but we only do single-image inference. We monkey-patch a stub
pyvips module so the model loads without installing the C library.
"""

import json
import os
import sys
import types
from pathlib import Path

import torch
from common.schema import WorkoutPage
from PIL import Image
from transformers import AutoModelForCausalLM, AutoTokenizer

from models_server.base import ServerModelRunner
from models_server.prompt import EXTRACTION_PROMPT

MODEL_ID = "vikhyatk/moondream2"
MODEL_REVISION = "2025-01-09"


def _patch_pyvips() -> None:
    """Install a stub pyvips module if the real one isn't available.

    moondream's image_crops.py imports pyvips at module level for
    multi-crop tiling. Single-image inference (our use case) never
    calls those functions, so a stub is safe.
    """
    if "pyvips" in sys.modules:
        return  # real pyvips already loaded

    stub = types.ModuleType("pyvips")

    class _StubImage:
        """Stub that raises if crop functions are accidentally called."""

        width = 100
        height = 100

        @staticmethod
        def new_from_array(_arr):
            return _StubImage()

        def resize(self, *_args, **_kwargs):
            return self

        def numpy(self):
            raise RuntimeError(
                "pyvips stub: multi-crop tiling requires real pyvips. "
                "Install libvips-dev and pyvips for multi-crop support."
            )

    stub.Image = _StubImage
    sys.modules["pyvips"] = stub


class MoondreamServerRunner(ServerModelRunner):
    model_id = MODEL_ID

    def load(self) -> None:
        _patch_pyvips()

        # Use local path from GCS if available, otherwise HF model ID
        model_path = os.environ.get("STRG_MOONDREAM_MODEL_PATH", self.model_id)
        print(f"[moondream] Loading from: {model_path}")

        # Clear stale transformers cache to avoid partial download issues
        import shutil

        cache_dir = os.path.join(
            os.environ.get("HF_HOME", "/tmp/hf-cache"),
            "modules",
            "transformers_modules",
            "moondream2",
        )
        if os.path.exists(cache_dir):
            shutil.rmtree(cache_dir, ignore_errors=True)
            print(f"[moondream] Cleared stale cache: {cache_dir}")

        self._tokenizer = AutoTokenizer.from_pretrained(
            model_path, trust_remote_code=model_path != self.model_id
        )
        torch_dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32

        # Retry with backoff for transient HF connection errors
        max_retries = 3
        for attempt in range(max_retries):
            try:
                self._model = AutoModelForCausalLM.from_pretrained(
                    model_path,
                    trust_remote_code=True,
                    torch_dtype=torch_dtype,
                )
                break
            except Exception as e:
                if attempt < max_retries - 1:
                    wait = 2**attempt
                    print(f"[moondream] Load attempt {attempt + 1} failed: {e}")
                    print(f"[moondream] Retrying in {wait}s...")
                    import time

                    time.sleep(wait)
                else:
                    raise

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
