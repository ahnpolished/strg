"""
Modal serverless deployment for strg-model API.
Deploys as a GPU-backed FastAPI endpoint that scales to zero.

Deploy:
  cd model
  modal deploy modal_app.py

Test:
  curl -X POST -F "image=@data/test/001.jpg" https://{username}--strg-model-serve.modal.run/predict

Teardown:
  modal app stop strg-model
"""

import os
from pathlib import Path

import modal

# Build the container image with all deps
image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install("build-essential", "curl")
    .pip_install(
        "torch>=2.4,<2.5",
        "transformers>=4.45,<4.50",
        "accelerate>=0.26",
        "pillow>=10.0",
        "sentencepiece>=0.2.0",
        "timm",
        "einops",
        "peft",
        "bitsandbytes",
        "fastapi",
        "uvicorn",
        "python-multipart",
    )
    # Copy our source code
    .add_local_dir(
        Path(__file__).parent / "models" / "server" / "src",
        remote_path="/app/models/server/src",
    )
    .add_local_dir(
        Path(__file__).parent / "packages" / "common" / "src",
        remote_path="/app/packages/common/src",
    )
)

app = modal.App("strg-model", image=image)

# Environment for the container
os.environ["PYTHONPATH"] = "/app/models/server/src:/app/packages/common/src"
os.environ["TORCH_COMPILE"] = "0"


@app.function(
    gpu="A10G",  # 24GB VRAM — enough for QLoRA
    timeout=600,  # 10 min for cold start
    container_idle_timeout=300,  # scale to zero after 5 min idle
    allow_concurrent_inputs=1,
)
@modal.asgi_app()
def serve():
    """Start the FastAPI server with LoRA checkpoint."""
    print("[modal] Loading model...", flush=True)

    # Set LoRA checkpoint (download from W&B)
    import wandb

    lora_dir = "/tmp/lora-checkpoint"
    api = wandb.Api()
    artifact = api.artifact("ahnpolished-ahnpolished/strg-model/qwen2-vl-lora:latest")
    artifact.download(lora_dir)

    os.environ["STRG_QWEN_LORA_CHECKPOINT"] = lora_dir

    from models_server.serve import app as fastapi_app

    return fastapi_app
