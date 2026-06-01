# Minimal Dockerfile for strg-model serverless worker.
# Uses the EXACT same setup as the pod (uv sync into .venv).

FROM pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl && rm -rf /var/lib/apt/lists/*

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app

# Copy workspace files
COPY model/pyproject.toml model/uv.lock /app/model/
COPY model/packages/common/ /app/model/packages/common/
COPY model/models/server/ /app/model/models/server/
COPY model/evaluation/ /app/model/evaluation/

# Mirror runpod_install_fast.sh: create venv with uv
RUN cd /app/model \
    && uv sync --package models-server --package evaluation --frozen --no-dev --no-cache 2>&1 | tail -5

# Install peft for LoRA
RUN cd /app/model && uv pip install peft --no-cache 2>&1 | tail -2

# Verify
RUN /app/model/.venv/bin/python -c "import torch; print('torch',torch.__version__,'CUDA',torch.cuda.is_available())"

ENV TORCH_COMPILE=0
ENV HF_HOME="/tmp/hf-cache"

EXPOSE 8000

# Use venv python (mirrors pod setup)
CMD ["/app/model/.venv/bin/python", "-m", "models_server.serve", "--port", "8000", "--host", "0.0.0.0"]
