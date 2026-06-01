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

# Install uv (fast Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app

# Copy dependency files first (for Docker layer caching)
COPY model/pyproject.toml model/uv.lock ./model/
COPY model/packages/common/pyproject.toml ./model/packages/common/
COPY model/models/server/pyproject.toml ./model/models/server/

# Install dependencies (using system torch from base image)
RUN cd model && uv sync --package models-server --frozen --no-dev --no-cache 2>&1 | tail -3

# Install peft for LoRA support
RUN cd model && uv pip install peft --no-cache 2>&1 | tail -2

# Copy source code (after deps for layer caching)
COPY model/packages/common/src/ ./model/packages/common/src/
COPY model/models/server/src/ ./model/models/server/src/

# Default env
ENV TORCH_COMPILE=0
ENV STRG_QWEN_LORA_CHECKPOINT=/lora
ENV PYTHONPATH="/app/model/models/server/src:/app/model/packages/common/src"

EXPOSE 8000

# Default: RunPod Serverless worker
# For FastAPI, override CMD in the RunPod template
CMD ["uv", "run", "--package", "models-server", "--directory", "/app/model", "python", "-m", "models_server.serverless_worker"]
