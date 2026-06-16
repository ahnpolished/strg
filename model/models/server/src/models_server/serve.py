"""FastAPI serving for the strg-model workout extraction API.

Usage:
  # Qwen2-VL-7B (default, high quality, ~130s):
  STRG_MODEL=qwen2-vl uv run python -m models_server.serve

  # Phi-3.5-Vision (recommended, ~20-35s, best accuracy/speed):
  STRG_MODEL=phi35 uv run python -m models_server.serve

  # Moondream2 (fastest, ~3-8s):
  STRG_MODEL=moondream uv run python -m models_server.serve

  # Custom host/port:
  uv run python -m models_server.serve --host 0.0.0.0 --port 8080

API:
  POST /predict
    - Upload an image file (multipart/form-data, field name "image")
    - Returns JSON with extracted workout entries

  POST /feedback
    - Submit corrected workout data for future fine-tuning.
    - Fields: image (file), entries (JSON), original_entries (JSON, optional)
    - Uploads photo + labels to GCS feedback bucket

  GET /health
    - Returns {"status": "ok", "model": "..."}

  GET /models
    - Returns list of available models and their status
"""

import io
import json
import os
import threading
import time
from pathlib import Path

from PIL import Image

try:
    import uvicorn
    from fastapi import FastAPI, File, Form, HTTPException, UploadFile
    from fastapi.responses import JSONResponse
except ImportError:
    msg = (
        "Missing serving dependencies. Install with:\n"
        "  uv add --package models-server fastapi uvicorn python-multipart"
    )
    raise ImportError(msg) from None

from common.schema import WorkoutPage

# Model definitions — loaded lazily at startup
AVAILABLE_MODELS = {
    "qwen2-vl": {
        "name": "Qwen2-VL-7B-Instruct",
        "params": "7B",
        "description": "Highest quality, slowest (~130s on L4)",
    },
    "phi35": {
        "name": "Phi-3.5-Vision-Instruct",
        "params": "3.8B",
        "description": "Best accuracy/speed trade-off (~20-35s on L4)",
    },
    "moondream": {
        "name": "Moondream2",
        "params": "1.8B",
        "description": "Fastest (~3-8s on L4), improves via feedback loop",
    },
}

SELECTED_MODEL = os.environ.get("STRG_MODEL", "qwen2-vl")
if SELECTED_MODEL not in AVAILABLE_MODELS:
    print(
        f"[serve] WARNING: Unknown STRG_MODEL='{SELECTED_MODEL}'. "
        f"Available: {list(AVAILABLE_MODELS.keys())}. Falling back to 'qwen2-vl'."
    )
    SELECTED_MODEL = "qwen2-vl"

app = FastAPI(
    title="strg-model Workout Extraction API",
    description="Extract structured workout data from handwritten journal photos",
    version="0.2.0",
)


@app.on_event("startup")
async def startup_warm_model():
    """Warm the model in a background thread so uvicorn starts immediately."""

    def _warm():
        print("[serve] Starting background model warm-up...")
        try:
            get_runner()
        except Exception as e:
            print(f"[serve] Model warm-up failed (will retry on first request): {e}")

    threading.Thread(target=_warm, daemon=True).start()


# Global model runner (loaded once at startup)
_runner = None

# GCS mount path (Cloud Run volume mount via gcsfuse).
# When set, predict images and feedback data are written directly to this
# mounted filesystem — no gsutil, no subprocess, no background threads.
# Falls back to local disk when not mounted (dev / non-GCP environments).
GCS_MOUNT = Path(os.environ.get("STRG_GCS_MOUNT", ""))
FEEDBACK_DIR = Path(os.environ.get("STRG_FEEDBACK_DIR", "data/feedback"))


def _create_runner():
    """Instantiate the runner for SELECTED_MODEL."""
    if SELECTED_MODEL == "qwen2-vl":
        from models_server.qwen2_vl import Qwen2VLRunner

        return Qwen2VLRunner()
    elif SELECTED_MODEL == "phi35":
        from models_server.phi35_server import Phi35VLRunner

        return Phi35VLRunner()
    elif SELECTED_MODEL == "moondream":
        from models_server.moondream_server import MoondreamServerRunner

        return MoondreamServerRunner()
    else:
        raise ValueError(f"Unknown model: {SELECTED_MODEL}")


def get_runner():
    global _runner
    if _runner is None:
        print(f"[serve] Loading model '{SELECTED_MODEL}'...")
        t0 = time.perf_counter()
        _runner = _create_runner()
        _runner.load()
        elapsed = time.perf_counter() - t0
        print(f"[serve] Model '{SELECTED_MODEL}' loaded in {elapsed:.1f}s")
    return _runner


def _persist_predict_image(image_id: str, image_bytes: bytes) -> Path | None:
    """Save predict image to GCS mount (or local fallback). Returns path."""
    if GCS_MOUNT.name:
        gcs_dir = GCS_MOUNT / "predict"
        gcs_dir.mkdir(parents=True, exist_ok=True)
        path = gcs_dir / f"{image_id}.jpg"
        path.write_bytes(image_bytes)
        print(f"[predict] Saved to GCS mount {path}")
        return path

    # Local fallback (dev / non-GCP)
    local_dir = FEEDBACK_DIR / "predict"
    local_dir.mkdir(parents=True, exist_ok=True)
    path = local_dir / f"{image_id}.jpg"
    path.write_bytes(image_bytes)
    print(f"[predict] Saved locally {path}")
    return path


def _persist_feedback(feedback_id: str, photo_bytes: bytes, entries_json: str) -> Path:
    """Save feedback photo + labels to GCS mount (or local fallback). Returns dir path."""
    if GCS_MOUNT.name:
        feedback_dir = GCS_MOUNT / "feedback" / feedback_id
        feedback_dir.mkdir(parents=True, exist_ok=True)
        (feedback_dir / "photo.jpg").write_bytes(photo_bytes)
        (feedback_dir / "ground_truth.json").write_text(entries_json)
        print(f"[feedback] Saved to GCS mount {feedback_dir}")
        return feedback_dir

    # Local fallback (dev / non-GCP)
    feedback_dir = FEEDBACK_DIR / feedback_id
    feedback_dir.mkdir(parents=True, exist_ok=True)
    (feedback_dir / "photo.jpg").write_bytes(photo_bytes)
    (feedback_dir / "ground_truth.json").write_text(entries_json)
    print(f"[feedback] Saved locally {feedback_dir}")
    return feedback_dir


@app.get("/health")
async def health():
    global _runner
    status = "ready" if _runner is not None else "warmup"
    model_info = AVAILABLE_MODELS.get(SELECTED_MODEL, {"name": SELECTED_MODEL})
    return {
        "status": status,
        "model": model_info["name"],
        "model_key": SELECTED_MODEL,
        "params": model_info.get("params", "?"),
        "device": getattr(_runner, "_model", None) is not None if _runner else False,
    }


@app.get("/models")
async def list_models():
    """Return available models and indicate which is active."""
    return {
        "active": SELECTED_MODEL,
        "available": {
            key: {
                **info,
                "active": key == SELECTED_MODEL,
            }
            for key, info in AVAILABLE_MODELS.items()
        },
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
    image_id = f"{SELECTED_MODEL}_{int(time.time() * 1000)}"
    tmp_path = tmp_dir / f"{image_id}.jpg"
    pil_image.save(tmp_path, "JPEG", quality=90)

    # Persist to GCS mount (synchronous, gcsfuse write is fast)
    _persist_predict_image(image_id, tmp_path.read_bytes())

    t0 = time.perf_counter()
    try:
        page: WorkoutPage = runner.predict(tmp_path)
        latency = time.perf_counter() - t0
        result = page.model_dump(mode="json")
        return {
            "entries": result.get("entries", []),
            "latency_s": round(latency, 2),
            "entry_count": len(page.entries),
            "model": SELECTED_MODEL,
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

    Uploads photo + corrected labels to GCS feedback bucket for the
    improvement loop: feedback → W&B labeling → fine-tune → redeploy.
    Falls back to local filesystem if GCS bucket is not configured.
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

    # Read image bytes
    contents = await image.read()

    # Create feedback ID
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    feedback_id = f"{SELECTED_MODEL}_{timestamp}"

    # Build the ground truth JSON
    data = {
        "entries": parsed,
        "original_entries": json.loads(original_entries) if original_entries else None,
        "notes": notes or "",
        "submitted_at": timestamp,
        "model": SELECTED_MODEL,
    }
    entries_json = json.dumps(data, indent=2)

    # Persist to GCS mount (or local fallback)
    save_path = _persist_feedback(feedback_id, contents, entries_json)
    on_gcs = GCS_MOUNT.name != ""

    return {
        "status": "ok",
        "feedback_id": feedback_id,
        "entries_saved": len(parsed),
        "storage": "gcs" if on_gcs else "local",
        "path": str(save_path),
    }


def main() -> None:
    global SELECTED_MODEL

    import argparse

    parser = argparse.ArgumentParser(description="Start strg-model API server")
    parser.add_argument("--host", default=os.environ.get("STRG_SERVE_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("STRG_SERVE_PORT", "8000")))
    parser.add_argument(
        "--model",
        default=SELECTED_MODEL,
        choices=list(AVAILABLE_MODELS.keys()),
        help="Model to serve (overrides STRG_MODEL env var)",
    )
    args = parser.parse_args()

    if args.model != SELECTED_MODEL:
        SELECTED_MODEL = args.model

    # Warm model before starting server (avoids timeout on first request)
    print(f"[serve] Warming model '{SELECTED_MODEL}'...")
    get_runner()
    print(f"[serve] Starting API at http://{args.host}:{args.port}")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
