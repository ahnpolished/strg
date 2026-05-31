#!/usr/bin/env bash
# pod-serve.sh - Start the strg-model API server on a RunPod GPU pod.
#
# Run via model-matrix-loop.sh --test-script path/to/pod-serve.sh
#
# The script:
#   1. Installs dependencies (uv sync)
#   2. Downloads the LoRA checkpoint from W&B
#   3. Starts the FastAPI server on port 8000
#   4. Tests the /health and /predict endpoints
#
# Environment:
#   WANDB_API_KEY  - required for downloading LoRA checkpoint
#   STRG_WANDB_ARTIFACT  - W&B artifact name (default: qwen2-vl-lora:latest)

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace/strg}"
MODEL="${STRG_TEST_MODEL:-qwen2-vl}"
WANDB_ARTIFACT="${STRG_WANDB_ARTIFACT:-qwen2-vl-lora:latest}"

echo "==================================================================="
echo "strg serve — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  model:      $MODEL"
echo "  workspace:  $WORKSPACE"
echo "  artifact:   $WANDB_ARTIFACT"
echo "==================================================================="

cd "$WORKSPACE"

# HuggingFace weights go to container disk
export HF_HOME="${HF_HOME:-/root/.hf-cache}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-/workspace/.uv-cache}"
mkdir -p "$HF_HOME" "$UV_CACHE_DIR"

# ── 1. Install dependencies ─────────────────────────────────────────────────
echo ""
echo "--- [1/4] Installing dependencies ---"
bash scripts/runpod_install_fast.sh server
export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"

VENV_PYTHON=".venv/bin/python"
if [[ ! -f "$VENV_PYTHON" ]]; then
  echo "ERROR: venv not found after install" >&2; exit 1
fi

# Disable torch.compile
export TORCH_COMPILE=0
export TORCHDYNAMO_ASYNC_COMPILATION=0
export PYTORCH_JIT=0

# ── 2. Download LoRA checkpoint from W&B ────────────────────────────────────
echo ""
echo "--- [2/4] Downloading LoRA checkpoint from W&B ---"
CKPT_DIR="${WORKSPACE}/checkpoints/${MODEL}"
mkdir -p "$CKPT_DIR"

if [[ -z "${WANDB_API_KEY:-}" ]]; then
  echo "WARNING: WANDB_API_KEY not set — serving without LoRA (base model only)."
else
  PYTHONUNBUFFERED=1 "$VENV_PYTHON" -c "
import wandb, sys
api = wandb.Api()
artifact = api.artifact('ahnpolished-ahnpolished/strg-model/${WANDB_ARTIFACT}')
artifact.download('${CKPT_DIR}')
print(f'Downloaded {len(artifact.files())} files to ${CKPT_DIR}')
" 2>&1 | tail -5
  echo "LoRA checkpoint ready at ${CKPT_DIR}"
fi

# ── 3. Start API server ─────────────────────────────────────────────────────
echo ""
echo "--- [3/4] Starting API server on port 8000 ---"

export STRG_QWEN_LORA_CHECKPOINT="$CKPT_DIR"
export STRG_SERVE_HOST="0.0.0.0"
export STRG_SERVE_PORT="8000"

# Start server in background
PYTHONUNBUFFERED=1 nohup "$VENV_PYTHON" -m models_server.serve \
  --host 0.0.0.0 --port 8000 > "${WORKSPACE}/serve.log" 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait for server to be ready (model download + load may take 2-5 min)
echo "Waiting for server startup (model download on first run)..."
for i in $(seq 1 120); do
  sleep 5
  if curl -s http://127.0.0.1:8000/health > /dev/null 2>&1; then
    echo "✅ Server ready after $((i * 5))s!"
    break
  fi
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "❌ Server process died!" >&2
    tail -30 "${WORKSPACE}/serve.log" >&2
    exit 1
  fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "  Still waiting... ($((i * 5))s elapsed)"
    tail -5 "${WORKSPACE}/serve.log" 2>/dev/null
  fi
done

# ── 4. Test endpoints ───────────────────────────────────────────────────────
echo ""
echo "--- [4/4] Testing API ---"

echo ""
echo "=== Health Check ==="
curl -s http://127.0.0.1:8000/health | python3 -m json.tool

echo ""
echo "=== Test Predict (data/test/001.jpg) ==="
if [[ -f "data/test/001.jpg" ]]; then
  TEST_OUTPUT=$(curl -s -X POST \
    -F "image=@data/test/001.jpg" \
    http://127.0.0.1:8000/predict)
  echo "$TEST_OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'  Entries: {data[\"entry_count\"]}')
print(f'  Latency: {data[\"latency_s\"]}s')
for e in data.get('entries', [])[:3]:
    print(f'    {e[\"exercise\"]}: {e[\"sets\"]}x{e[\"reps\"]} @ {e.get(\"weight_kg\") or e.get(\"weight_lbs\",\"?\")}')
  "
  echo ""
  echo "OVERALL: PASS"
else
  echo "WARNING: data/test/001.jpg not found — skipping predict test"
fi

echo ""
echo "==================================================================="
echo "strg serve complete — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Server PID: $SERVER_PID"
echo "  Server URL: http://$(curl -s http://127.0.0.1:8000/health 2>/dev/null | python3 -c \"import json,sys; d=json.load(sys.stdin); print(d.get('device',''))\" 2>/dev/null):8000"
echo "  API: POST /predict (multipart form, field 'image')"
echo "  API: GET  /health"
echo "==================================================================="

# Keep server running (don't exit - matrix loop will teardown the pod)
echo "Server running on port 8000. Waiting for termination signal..."
tail -f "${WORKSPACE}/serve.log"
