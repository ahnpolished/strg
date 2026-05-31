# Dockerfile for strg-model serving API.
#
# Build:
#   docker build -t strg-model:latest -f models/server/docker/Dockerfile .
#
# Run (base Qwen2-VL):
#   docker run --gpus all -p 8000:8000 strg-model:latest
#
# Run (with LoRA adapter):
#   docker run --gpus all -p 8000:8000 \
#     -v /path/to/lora:/lora \
#     -e STRG_QWEN_LORA_CHECKPOINT=/lora \
#     strg-model:latest
#
# Environment variables:
#   STRG_QWEN_LORA_CHECKPOINT  - path to LoRA adapter (optional)
#   STRG_QWEN_MIN_VISUAL_TOKENS  - min visual token count (default: 256)
#   STRG_QWEN_MAX_VISUAL_TOKENS  - max visual token count (default: 1280)
#   STRG_QWEN_MAX_NEW_TOKENS  - max generation tokens (default: 1536)
#   STRG_SERVE_HOST           - API host (default: 0.0.0.0)
#   STRG_SERVE_PORT           - API port (default: 8000)
#
# Requires: NVIDIA GPU with >=16GB VRAM, CUDA 12.x runtime.

FROM pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app

# Copy project files
COPY pyproject.toml uv.lock ./
COPY packages/common/ packages/common/
COPY models/server/ models/server/

# Install dependencies (without dev groups)
RUN uv sync --package models-server --group serve --frozen --no-dev

# Pre-download model weights on build (saves startup time)
# This adds ~15GB to the image. Comment out to download at runtime.
# RUN uv run --package models-server python -c " \
#     from transformers import AutoProcessor, Qwen2VLForConditionalGeneration; \
#     AutoProcessor.from_pretrained('Qwen/Qwen2-VL-7B-Instruct'); \
#     Qwen2VLForConditionalGeneration.from_pretrained('Qwen/Qwen2-VL-7B-Instruct', torch_dtype='auto') \
# "

ENV STRG_SERVE_HOST=0.0.0.0
ENV STRG_SERVE_PORT=8000

EXPOSE 8000

CMD ["uv", "run", "--package", "models-server", "python", "-m", "models_server.serve"]
