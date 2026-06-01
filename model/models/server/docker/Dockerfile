FROM runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"
WORKDIR /app
COPY model/ /app/model/
RUN cd /app/model && uv sync --package models-server --package evaluation --frozen --no-dev 2>&1 | tail -3 && uv pip install peft 2>&1 | tail -1
ENV PYTHONPATH="/app/model/models/server/src:/app/model/packages/common/src"
ENV TORCH_COMPILE=0 HF_HOME="/tmp/hf-cache"
EXPOSE 8000
CMD ["/app/model/.venv/bin/python", "-m", "models_server.serve", "--port", "8000", "--host", "0.0.0.0"]
