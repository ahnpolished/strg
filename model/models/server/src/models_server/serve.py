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

  POST /feedback
    - Submit corrected workout data for future fine-tuning.
    - Fields: image (file), entries (JSON), original_entries (JSON, optional)
    - Saves to {STRG_FEEDBACK_DIR}/{timestamp}/

  GET /health
    - Returns {"status": "ok", "model": "..."}
"""

import io
import json
import os
import time
from pathlib import Path

from PIL import Image

try:
    import uvicorn
    from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
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

# Feedback directory for collecting corrected data
FEEDBACK_DIR = Path(os.environ.get("STRG_FEEDBACK_DIR", "data/feedback"))


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
    """Warm up the model on server start (non-blocking)."""
    import asyncio

    asyncio.create_task(_warm_model())


async def _warm_model():
    """Background model loading."""
    get_runner()


@app.get("/health")
async def health():
    global _runner
    status = "ready" if _runner is not None and hasattr(_runner, "_model") else "warmup"
    lora = os.environ.get("STRG_QWEN_LORA_CHECKPOINT", "")
    device = (
        str(_runner._model.device)
        if _runner is not None and hasattr(_runner, "_model")
        else "loading"
    )
    return {
        "status": status,
        "model": "Qwen2-VL-7B-Instruct",
        "lora_checkpoint": lora or None,
        "device": device,
    }


@app.post("/")
@app.post("/serverless/predict")
async def serverless_predict(request: Request):
    """Handle RunPod serverless JSON format: {"input": {"image": "<base64>"}}."""
    runner = get_runner()
    body = await request.json()
    inp = body.get("input", body)

    image_b64 = inp.get("image", "")
    if not image_b64:
        raise HTTPException(status_code=400, detail="No 'image' in input")

    try:
        import base64

        image_bytes = base64.b64decode(image_b64)
        pil_image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid image: {e}") from e

    tmp_dir = Path("/tmp/strg-serve")
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = tmp_dir / f"sless_{int(time.time())}.jpg"
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
        if tmp_path.exists():
            tmp_path.unlink()


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


@app.post("/feedback", response_class=JSONResponse)
async def feedback(
    image: UploadFile = File(...),
    entries: str = Form(...),
    original_entries: str | None = Form(None),
    notes: str | None = Form(None),
):
    """Submit corrected workout data to use in future fine-tuning.

    Saves the photo + corrected entries to the feedback directory.
    This data feeds back into the training pipeline for continuous improvement.
    """
    if not image.content_type or not image.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Only image files are accepted")

    # Validate entries JSON
    try:
        parsed = json.loads(entries)
        if not isinstance(parsed, list):
            raise ValueError("entries must be a list")
    except (json.JSONDecodeError, ValueError) as e:
        raise HTTPException(status_code=400, detail=f"Invalid entries JSON: {e}") from e

    # Create feedback directory
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    feedback_id = f"feedback_{timestamp}"
    save_dir = FEEDBACK_DIR / feedback_id
    save_dir.mkdir(parents=True, exist_ok=True)

    # Save the image
    contents = await image.read()
    img_path = save_dir / "photo.jpg"
    img_path.write_bytes(contents)

    # Save corrected entries
    data = {
        "entries": parsed,
        "original_entries": json.loads(original_entries) if original_entries else None,
        "notes": notes or "",
        "submitted_at": timestamp,
    }
    json_path = save_dir / "ground_truth.json"
    json_path.write_text(json.dumps(data, indent=2))

    print(f"[feedback] Saved corrected data to {save_dir} ({len(parsed)} entries)")

    return {
        "status": "ok",
        "feedback_id": feedback_id,
        "entries_saved": len(parsed),
    }


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
