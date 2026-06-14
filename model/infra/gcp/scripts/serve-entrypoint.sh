#!/bin/bash
# ── Cloud Run entrypoint ────────────────────────────────────────────
# 1. Download base model weights + LoRA adapter from GCS (cold start)
# 2. Start uvicorn with the FastAPI serve app
#
# On warm starts (container reuse), the download is skipped if the
# model directory already exists.
#
# Expected env vars (set by Cloud Run / Terraform):
#   GCS_BUCKET               GCS bucket name (required)
#   STRG_QWEN_MODEL_PATH     Local path for base model weights
#   STRG_QWEN_LORA_CHECKPOINT Local path for LoRA adapter
#   STRG_QWEN_LOAD_IN_4BIT   "true" / "false"
#   PORT                     Cloud Run-provided port (default 8080)

set -euo pipefail

echo "=== strg-model Cloud Run entrypoint ==="
echo "GCS_BUCKET=${GCS_BUCKET:-NOT SET}"
echo "PORT=${PORT:-8080}"

MODEL_DIR="/tmp/model"
MODEL_PATH="${STRG_QWEN_MODEL_PATH:-$MODEL_DIR/Qwen2-VL-7B-Instruct}"
LORA_PATH="${STRG_QWEN_LORA_CHECKPOINT:-$MODEL_DIR/lora}"
SERVER_PORT="${PORT:-8080}"

# ── Download weights from GCS (cold start only) ─────────────────────
if [ -n "${GCS_BUCKET:-}" ]; then
  if [ ! -f "$MODEL_DIR/.weights_ready" ]; then
    echo "[entrypoint] Downloading base model from gs://${GCS_BUCKET}/weights/Qwen2-VL-7B-Instruct/ ..."
    mkdir -p "$MODEL_PATH"
    gsutil -m cp -r \
      "gs://${GCS_BUCKET}/weights/Qwen2-VL-7B-Instruct/*" \
      "$MODEL_PATH/"

    echo "[entrypoint] Downloading LoRA adapter from gs://${GCS_BUCKET}/weights/lora/ ..."
    mkdir -p "$LORA_PATH"
    gsutil -m cp -r \
      "gs://${GCS_BUCKET}/weights/lora/*" \
      "$LORA_PATH/"

    touch "$MODEL_DIR/.weights_ready"
    echo "[entrypoint] Weights download complete."
  else
    echo "[entrypoint] Weights already present — skipping download (warm start)."
  fi
else
  echo "[entrypoint] WARNING: GCS_BUCKET not set — skipping weight download."
fi

# ── Start the FastAPI server ────────────────────────────────────────
export STRG_QWEN_MODEL_PATH="$MODEL_PATH"
export STRG_QWEN_LORA_CHECKPOINT="$LORA_PATH"
export STRG_SERVE_PORT="$SERVER_PORT"
export HF_HOME="${HF_HOME:-/tmp/hf-cache}"

echo "[entrypoint] Starting uvicorn on 0.0.0.0:${SERVER_PORT} ..."
exec /app/.venv/bin/python -m uvicorn models_server.serve:app \
  --host 0.0.0.0 \
  --port "${SERVER_PORT}" \
  --log-level info \
  --timeout-keep-alive 120
