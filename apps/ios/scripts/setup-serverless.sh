#!/usr/bin/env bash
# setup-serverless.sh — Deploy strg-model as a RunPod Serverless endpoint.
#
# RunPod Serverless auto-scales GPUs, no SSH tunnels needed, and your
# iPhone app calls the endpoint URL directly.
#
# Usage:
#   ./apps/ios/scripts/setup-serverless.sh
#
# Prerequisites:
#   1. Docker Desktop (for building the image)
#   2. A container registry account (Docker Hub, GitHub Container Registry, etc.)
#
# Steps (automated):
#   1. Build the Docker image with our API + LoRA checkpoint baked in
#   2. Push to container registry
#   3. Print instructions for RunPod Console setup
#
# After setup, your endpoint URL looks like:
#   https://api.runpod.ai/v2/<endpoint-id>/runsync

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODEL_DIR="$REPO_ROOT/model"
CHECKPOINT_DIR="$MODEL_DIR/models/server/checkpoints/qwen2-vl-lora"

echo "========================================"
echo " strg — RunPod Serverless Setup"
echo "========================================"
echo ""

# ── 1. Verify checkpoint exists ─────────────────────────────────────────────
echo "--- [1/3] Checking LoRA checkpoint ---"
if [[ -d "$CHECKPOINT_DIR" ]] && [[ -f "$CHECKPOINT_DIR/adapter_model.safetensors" ]]; then
    echo "  ✅ Local checkpoint found: $CHECKPOINT_DIR"
else
    echo ""
    echo "  ❌ LoRA checkpoint not found locally."
    echo "     Pull from W&B:"
    echo "     cd $MODEL_DIR && uv run python -c 'import wandb; wandb.Api().artifact(\"ahnpolished-ahnpolished/strg-model/qwen2-vl-lora:latest\").download(\"models/server/checkpoints/qwen2-vl-lora\")'"
    echo ""
    exit 1
fi

# ── 2. Get container registry info ──────────────────────────────────────────
echo ""
echo "--- [2/3] Container registry ---"
echo ""
echo "  Enter your Docker Hub username (or GitHub Container Registry):"
read -p "  Registry username: " REGISTRY_USER
read -p "  Image name [strg-model]: " IMAGE_NAME
IMAGE_NAME="${IMAGE_NAME:-strg-model}"
echo ""
echo "  Building: $REGISTRY_USER/$IMAGE_NAME:latest"

cd "$REPO_ROOT"

# Build the Docker image
docker build -t "$REGISTRY_USER/$IMAGE_NAME:latest" \
  -f models/server/docker/Dockerfile \
  --build-arg LORA_CHECKPOINT="$CHECKPOINT_DIR" \
  . 2>&1 | tail -5

echo ""
echo "  Pushing to registry..."
docker push "$REGISTRY_USER/$IMAGE_NAME:latest" 2>&1 | tail -5

# ── 3. Print RunPod Console instructions ────────────────────────────────────
echo ""
echo "--- [3/3] RunPod Console setup ---"
echo ""
echo "========================================"
echo " ✅ Image pushed!"
echo "========================================"
echo ""
echo "  Now configure in RunPod Console:"
echo ""
echo "  1. Go to https://www.runpod.io/console/serverless"
echo ""
echo "  2. Create a Serverless Template:"
echo "     Name:        strg-model"
echo "     Image:       $REGISTRY_USER/$IMAGE_NAME:latest"
echo "     Container:   $REGISTRY_USER/$IMAGE_NAME:latest"
echo "     Command:     uv run --package models-server python -m models_server.serverless_worker"
echo "     Env vars:"
echo "       HF_TOKEN=<your-huggingface-token>"
echo "       TORCH_COMPILE=0"
echo ""
echo "  3. Create an Endpoint from that template:"
echo "     GPU Type:    Any 24GB+ (RTX 3090, A5000, A40)"
echo "     Min Workers: 0 (scale to zero when idle)"
echo "     Max Workers: 2"
echo "     Idle Timeout: 30s"
echo ""
echo "  4. Your endpoint URL will look like:"
echo "     https://api.runpod.ai/v2/<endpoint-id>/runsync"
echo ""
echo "  5. Paste that URL (without /runsync) into the app:"
echo "     https://api.runpod.ai/v2/<endpoint-id>"
echo ""
echo "  🛑  To stop: Delete the endpoint in RunPod Console"
echo "========================================"
