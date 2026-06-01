"""
RunPod Serverless worker for strg-model.

This handles inference requests from RunPod's serverless infrastructure.
Deploy as a Docker container and configure in RunPod console.

RunPod serverless worker protocol:
- Receives JSON with input data via POST
- Returns JSON with prediction results
- Uses the runpod SDK for request/response handling

API:
  Input (JSON):
    {
      "input": {
        "image": "<base64-encoded-image>",
        "filename": "photo.jpg"
      }
    }

  Output (JSON):
    {
      "output": {
        "entries": [...],
        "entry_count": 3,
        "latency_s": 7.2
      }
    }
"""

import base64
import io
import json
import time
from pathlib import Path

from PIL import Image

# Import our model runner
from models_server.qwen2_vl import Qwen2VLRunner

# Global model (loaded once per worker)
_runner: Qwen2VLRunner | None = None


def get_runner() -> Qwen2VLRunner:
    global _runner
    if _runner is None:
        print("[serverless] Loading model...")
        t0 = time.perf_counter()
        _runner = Qwen2VLRunner()
        _runner.load()
        elapsed = time.perf_counter() - t0
        print(f"[serverless] Model loaded in {elapsed:.1f}s")
    return _runner


def handler(event: dict) -> dict:
    """RunPod serverless handler.

    Args:
        event: The input event from RunPod. Expected format:
            {"input": {"image": "<base64>", "filename": "photo.jpg"}}

    Returns:
        Response dict with prediction results.
    """
    inp = event.get("input", {})

    # Decode base64 image
    image_b64 = inp.get("image", "")
    if not image_b64:
        return {"error": "No image provided"}

    try:
        image_bytes = base64.b64decode(image_b64)
        pil_image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception as e:
        return {"error": f"Invalid image: {e}"}

    # Save to temp file
    tmp_dir = Path("/tmp/strg-serverless")
    tmp_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = tmp_dir / f"input_{int(time.time())}.jpg"
    pil_image.save(tmp_path, "JPEG", quality=90)

    # Run inference
    t0 = time.perf_counter()
    try:
        runner = get_runner()
        page = runner.predict(tmp_path)
        latency = time.perf_counter() - t0
        result = page.model_dump(mode="json")
        return {
            "entries": result.get("entries", []),
            "entry_count": len(page.entries),
            "latency_s": round(latency, 2),
        }
    except Exception as e:
        return {"error": f"Prediction failed: {e}"}
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


# For local testing
if __name__ == "__main__":
    import sys
    path = sys.argv[1] if len(sys.argv) > 1 else "data/test/001.jpg"
    with open(path, "rb") as f:
        img_b64 = base64.b64encode(f.read()).decode()
    result = handler({"input": {"image": img_b64, "filename": Path(path).name}})
    print(json.dumps(result, indent=2))
