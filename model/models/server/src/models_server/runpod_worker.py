"""
RunPod Serverless worker using the standard handler protocol.
This is the ONLY way to get RunPod to dispatch jobs to the worker.
"""

import base64
import io
import time
from pathlib import Path

from PIL import Image

# Initialize model lazily (once per worker)
_runner = None


def get_runner():
    global _runner
    if _runner is None:
        from models_server.qwen2_vl import Qwen2VLRunner

        print("[worker] Loading model...", flush=True)
        t0 = time.perf_counter()
        _runner = Qwen2VLRunner()
        _runner.load()
        elapsed = time.perf_counter() - t0
        print(f"[worker] Model loaded in {elapsed:.1f}s", flush=True)
    return _runner


def handler(job: dict) -> dict:
    """
    RunPod serverless handler — receives a job dict and returns results.
    Called by the runpod SDK's internal event loop.
    """
    inp = job.get("input", {})
    image_b64 = inp.get("image", "")

    if not image_b64:
        return {"error": "No image in input"}

    try:
        image_bytes = base64.b64decode(image_b64)
        pil_image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception as e:
        return {"error": f"Invalid image: {e}"}

    tmp_path = Path("/tmp/strg-worker.jpg")
    pil_image.save(tmp_path, "JPEG", quality=90)

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


# RunPod SDK: start the worker event loop
if __name__ == "__main__":
    import runpod

    print("[worker] Starting RunPod serverless worker...", flush=True)
    runpod.serverless.start({"handler": handler})
