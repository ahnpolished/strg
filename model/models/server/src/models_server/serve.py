"""FastAPI serving for the strg-model workout extraction API.

Usage:
  # Start server (base Qwen2-VL):
  uv run python -m models_server.serve

  # With LoRA checkpoint:
  STRG_QWEN_LORA_CHECKPOINT=/path/to/lora uv run python -m models_server.serve

  # Custom host/port:
  uv run python -m models_server.serve --host 0.0.0.0 --port 8080

API:
  POST /predict
    - Upload an image file (multipart/form-data, field name "image")
    - Returns JSON with extracted workout entries

  GET /health
    - Returns {"status": "ok", "model": "..."}
"""

import io
import os
import time
from pathlib import Path

from PIL import Image

try:
    import uvicorn
    from fastapi import FastAPI, File, HTTPException, UploadFile
    from fastapi.responses import JSONResponse
except ImportError:
    msg = (
        "Missing serving dependencies. Install with:\n"
        "  uv add --package models-server fastapi uvicorn python-multipart"
    )
    raise ImportError(msg) from None

from common.schema import WorkoutPage

from models_server.qwen2_vl import Qwen2VLRunner

app = FastAPI(
    title="strg-model Workout Extraction API",
    description="Extract structured workout data from handwritten journal photos",
    version="0.1.0",
)

# Global model runner (loaded once at startup)
_runner: Qwen2VLRunner | None = None


def get_runner() -> Qwen2VLRunner:
    global _runner
    if _runner is None:
        print("[serve] Loading model...")
        t0 = time.perf_counter()
        _runner = Qwen2VLRunner()
        _runner.load()
        elapsed = time.perf_counter() - t0
        print(f"[serve] Model loaded in {elapsed:.1f}s")
    return _runner


@app.on_event("startup")
async def startup():
    """Warm up the model on server start."""
    _ = get_runner()


@app.get("/health")
async def health():
    runner = get_runner()
    model_name = runner.model_id
    lora = os.environ.get("STRG_QWEN_LORA_CHECKPOINT", "")
    return {
        "status": "ok",
        "model": model_name,
        "lora_checkpoint": lora or None,
        "device": str(runner._model.device) if hasattr(runner, "_model") else "unknown",
    }


@app.post("/predict", response_class=JSONResponse)
async def predict(image: UploadFile = File(...)):
    """Upload a workout journal photo and get structured workout data."""
    if not image.content_type or not image.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Only image files are accepted")

    runner = get_runner()

    # Read uploaded image
    contents = await image.read()
    try:
        pil_image = Image.open(io.BytesIO(contents)).convert("RGB")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid image: {e}") from e

    # Save to temp file for the runner
    tmp_dir = Path("/tmp/strg-serve")
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = tmp_dir / f"upload_{int(time.time())}.jpg"
    pil_image.save(tmp_path, "JPEG", quality=90)

    t0 = time.perf_counter()
    try:
        page: WorkoutPage = runner.predict(tmp_path)
        latency = time.perf_counter() - t0
        result = page.model_dump(mode="json")
        return {
            "entries": result.get("entries", []),
            "latency_s": round(latency, 2),
            "entry_count": len(page.entries),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Prediction failed: {e}") from e
    finally:
        # Clean up temp file
        if tmp_path.exists():
            tmp_path.unlink()


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Start strg-model API server")
    parser.add_argument("--host", default=os.environ.get("STRG_SERVE_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("STRG_SERVE_PORT", "8000")))
    args = parser.parse_args()

    # Warm model before starting server (avoids timeout on first request)
    print("[serve] Warming model...")
    get_runner()
    print(f"[serve] Starting API at http://{args.host}:{args.port}")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
