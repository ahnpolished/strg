# Dockerfile for strg-model — RunPod Serverless worker.
#
# No model weights baked in — they download at runtime (~30s on RunPod).
# Image size: ~8GB (fits GHA 14GB runner limit).

FROM pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime

# Minimize size
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy everything
COPY model/ ./model/

# Install deps — use python3 -m pip to be sure we hit the right pip
# No pipe to tail — let errors be visible in build logs
RUN python3 -m pip install --no-cache-dir \
    "transformers>=4.45,<4.50" \
    "accelerate>=0.26" \
    "pillow>=10.0" \
    "sentencepiece>=0.2.0" \
    timm einops peft bitsandbytes \
    fastapi uvicorn python-multipart

# Verify install succeeded
RUN python3 --version \
    && python3 -c "import transformers;import peft;import PIL;import torch;print('torch',torch.__version__,'CUDA',torch.cuda.is_available())" \
    && echo "✅ All deps verified"

# Paths for our source modules
ENV PYTHONPATH="/app/model/models/server/src:/app/model/packages/common/src"
ENV TORCH_COMPILE=0
ENV HF_HOME="/tmp/hf-cache"

EXPOSE 8000

# RunPod Serverless: start FastAPI HTTP server on port 8000.
# RunPod routes external requests → container:8000 via --ports flag.
CMD ["python3", "-m", "models_server.serve", "--port", "8000", "--host", "0.0.0.0"]
