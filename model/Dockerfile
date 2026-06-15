# ── GCP Cloud Run GPU serving container ─────────────────────────────
#
# Build from the model/ workspace root:
#   cd model
#   docker build -f Dockerfile -t <repo-url>/serve:latest .
#
# The image contains ONLY the Python code. Weights are downloaded from
# GCS at cold start (faster iteration, smaller image, no 15 GB layers).
#
# Layer strategy: copy dependency files first → uv sync (cached unless
# deps change), then copy source code → chmod entrypoint (fast layer).

FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

# Install gcloud SDK for gsutil (weight download at cold start).
# This also installs curl, which the uv installer below depends on —
# must run before the uv install step.
RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
       > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
       | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && apt-get update && apt-get install -y --no-install-recommends \
       google-cloud-cli \
       build-essential \
       pkg-config \
       libvips-dev \
    && rm -rf /var/lib/apt/lists/*

# Install uv (fast Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app

# ── Layer 1: dependency files only (rarely changes → high cache hit) ──
COPY pyproject.toml uv.lock ./
COPY packages/common/pyproject.toml       packages/common/
COPY models/server/pyproject.toml         models/server/
COPY models/local/pyproject.toml          models/local/
COPY evaluation/pyproject.toml            evaluation/

# Create minimal package stubs so hatchling can build workspace members
# during uv sync. The real source is copied in Layer 2.
RUN mkdir -p packages/common/src/common \
    models/server/src/models_server \
    models/local/src/models_local \
    && touch packages/common/src/common/__init__.py \
    models/server/src/models_server/__init__.py \
    models/local/src/models_local/__init__.py

# Install Python dependencies via uv (cached unless dep files change)
# --no-dev excludes ruff/ty for smaller image
RUN uv sync --package models-server --no-dev

# Explicitly install pyvips (moondream2 dependency).
# uv sync may not resolve its platform-specific binary wheel correctly.
# The manylinux wheel needs libvips-dev at runtime (installed above).
RUN /app/.venv/bin/pip install --no-deps pyvips>=2.2.3

# ── Layer 2: source code + scripts (frequently changes, but fast) ───
COPY . .
RUN chmod +x infra/gcp/scripts/serve-entrypoint.sh

# Environment
ENV PYTHONPATH="/app/models/server/src:/app/models/local/src:/app/packages/common/src"
ENV HF_HOME="/tmp/hf-cache"
ENV TORCH_COMPILE="0"
ENV STRG_MODEL="moondream"

# Cloud Run provides $PORT (default 8080)
EXPOSE 8080

ENTRYPOINT ["/app/infra/gcp/scripts/serve-entrypoint.sh"]
