#!/bin/bash
# ── Cloud Run entrypoint ────────────────────────────────────────────
# 1. Download model weights from GCS based on STRG_MODEL (cold start)
# 2. Start uvicorn with the FastAPI serve app
#
# On warm starts (container reuse), the download is skipped if the
# model directory already exists.
#
# Supported models: moondream (default, fast), phi35, qwen2-vl
#
# Expected env vars (set by Cloud Run / Terraform):
#   GCS_BUCKET               GCS bucket name (required)
#   STRG_MODEL               Model to serve: moondream|phi35|qwen2-vl
#   STRG_QWEN_MODEL_PATH     Local path for Qwen2-VL base model
#   STRG_QWEN_LORA_CHECKPOINT Local path for Qwen2-VL LoRA adapter
#   STRG_PHI35_MODEL_PATH    Local path for Phi-3.5 base model
#   STRG_FEEDBACK_GCS_BUCKET GCS bucket for /feedback uploads
#   PORT                     Cloud Run-provided port (default 8080)

set -euo pipefail

echo "=== strg-model Cloud Run entrypoint ==="
echo "GCS_BUCKET=${GCS_BUCKET:-NOT SET}"
echo "STRG_MODEL=${STRG_MODEL:-moondream}"
echo "PORT=${PORT:-8080}"

MODEL_DIR="/tmp/model"
MODEL="${STRG_MODEL:-moondream}"
SERVER_PORT="${PORT:-8080}"

# ── Download weights from GCS (cold start only) ─────────────────────
if [ -n "${GCS_BUCKET:-}" ]; then
  if [ ! -f "$MODEL_DIR/.weights_ready" ]; then
    case "$MODEL" in
      qwen2-vl)
        QWEN_PATH="${STRG_QWEN_MODEL_PATH:-$MODEL_DIR/Qwen2-VL-7B-Instruct}"
        LORA_PATH="${STRG_QWEN_LORA_CHECKPOINT:-$MODEL_DIR/lora}"

        echo "[entrypoint] Downloading Qwen2-VL-7B base model..."
        mkdir -p "$QWEN_PATH"
        gsutil -m cp -r \
          "gs://${GCS_BUCKET}/weights/Qwen2-VL-7B-Instruct/*" \
          "$QWEN_PATH/" 2>/dev/null || echo "  (skipped — may download from HF)"

        echo "[entrypoint] Downloading Qwen2-VL LoRA adapter..."
        mkdir -p "$LORA_PATH"
        gsutil -m cp -r \
          "gs://${GCS_BUCKET}/weights/lora/*" \
          "$LORA_PATH/" 2>/dev/null || echo "  (skipped — no LoRA available)"
        ;;

      phi35)
        PHI35_PATH="${STRG_PHI35_MODEL_PATH:-$MODEL_DIR/Phi-3.5-vision-instruct}"
        PHI35_LORA="${STRG_PHI35_LORA_CHECKPOINT:-$MODEL_DIR/phi35-lora}"

        echo "[entrypoint] Downloading Phi-3.5-Vision base model..."
        mkdir -p "$PHI35_PATH"
        gsutil -m cp -r \
          "gs://${GCS_BUCKET}/weights/Phi-3.5-vision-instruct/*" \
          "$PHI35_PATH/" 2>/dev/null || {
            echo "  Phi-3.5 weights not in GCS — will download from HuggingFace."
            export STRG_PHI35_MODEL_PATH="microsoft/Phi-3.5-vision-instruct"
          }

        echo "[entrypoint] Downloading Phi-3.5 LoRA adapter..."
        mkdir -p "$PHI35_LORA"
        gsutil -m cp -r \
          "gs://${GCS_BUCKET}/weights/phi35-lora/*" \
          "$PHI35_LORA/" 2>/dev/null || echo "  (skipped — no LoRA available)"
        ;;

      moondream)
        echo "[entrypoint] Moondream2 (~4 GB) — downloading from HuggingFace."
        echo "  First cold start will download and cache in /tmp/hf-cache."
        echo "  Subsequent warm starts reuse the cache."
        mkdir -p /tmp/hf-cache
        ;;

      *)
        echo "[entrypoint] WARNING: Unknown STRG_MODEL='$MODEL'. Using moondream."
        export STRG_MODEL="moondream"
        mkdir -p /tmp/hf-cache
        ;;
    esac

    mkdir -p "$MODEL_DIR"
    touch "$MODEL_DIR/.weights_ready"
    echo "[entrypoint] Weights download complete."
  else
    echo "[entrypoint] Weights already present — skipping download (warm start)."
  fi
else
  echo "[entrypoint] WARNING: GCS_BUCKET not set — models will download from HF."
fi

# ── Start the FastAPI server ────────────────────────────────────────
export STRG_SERVE_PORT="$SERVER_PORT"
export HF_HOME="${HF_HOME:-/tmp/hf-cache}"
export PYTHONPATH="/app/models/server/src:/app/packages/common/src"

echo "[entrypoint] Starting strg-model server with STRG_MODEL=$MODEL on 0.0.0.0:${SERVER_PORT} ..."
exec /app/.venv/bin/python -m models_server.serve \
  --host 0.0.0.0 \
  --port "${SERVER_PORT}"
