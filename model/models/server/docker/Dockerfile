# Dockerfile for strg-model — serves on RunPod Serverless or FastAPI.
#
# IMPORTANT: This image does NOT bake in the 15GB model weights.
# The model downloads at runtime (takes ~30s on RunPod's fast network).
# This keeps the image under 10GB so it fits GHA runner limits (14GB).
#
# Build (manual):
#   docker build -t ghcr.io/your-org/strg-model:latest -f model/models/server/docker/Dockerfile .
#
# Run (FastAPI):
#   docker run --gpus all -p 8000:8000 \
#     -e STRG_QWEN_LORA_CHECKPOINT=/lora \
#     -v /path/to/lora:/lora \
#     ghcr.io/your-org/strg-model:latest \
#     uv run --package models-server python -m models_server.serve
#
# Run (RunPod Serverless — default CMD):
#   Deploy via RunPod Console, set container disk to 20GB+.
#   Model downloads at startup (~30s cold start).
#
# Environment:
#   STRG_QWEN_LORA_CHECKPOINT  - path to LoRA adapter (default: /lora)
#   HF_TOKEN        - HuggingFace token (for downloading model)
#   TORCH_COMPILE=0 - disable torch.compile (saves memory)

FROM pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime

# Minimize size: clean apt cache
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy all source code
COPY model/ ./model/

# Install dependencies system-wide (so system python can find them)
RUN pip install --no-cache-dir \
    "transformers>=4.45,<4.50" \
    "accelerate>=0.26" \
    "pillow>=10.0" \
    "sentencepiece>=0.2.0" \
    timm \
    einops \
    peft \
    bitsandbytes \
    2>&1 | tail -5

# Verify python and key modules are available
RUN python3 --version && python3 -c "import transformers; import PIL; print('deps OK')"

# Default env
ENV TORCH_COMPILE=0
ENV STRG_QWEN_LORA_CHECKPOINT=/lora
ENV PYTHONPATH="/app/model/models/server/src:/app/model/packages/common/src"

EXPOSE 8000

# Default: RunPod Serverless worker
# For FastAPI, override CMD in the RunPod template
# Use system python (has torch pre-installed) with PYTHONPATH set
CMD ["python3", "-m", "models_server.serverless_worker"]
