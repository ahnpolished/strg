#!/usr/bin/env bash
# pod-finetune.sh - Fine-tune a model on a RunPod GPU pod.
#
# Run via model-matrix-loop.sh --test-script path/to/pod-finetune.sh
# Environment overrides:
#   STRG_FINETUNE_MODEL  - model to fine-tune: qwen2-vl | internvl2
#   STRG_TRAIN_DIR       - training data (default: data/train)
#   STRG_VAL_DIR         - validation data (default: data/val)
#   STRG_OUTPUT_DIR      - checkpoint output (default: checkpoints/<model>)
#   STRG_EPOCHS          - training epochs (default: 3)
#   WANDB_API_KEY        - enables W&B logging

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace/strg}"
MODEL="${STRG_FINETUNE_MODEL:-qwen2-vl}"
TRAIN_DIR="${STRG_TRAIN_DIR:-${WORKSPACE}/data/train}"
VAL_DIR="${STRG_VAL_DIR:-${WORKSPACE}/data/val}"
OUTPUT_DIR="${STRG_OUTPUT_DIR:-${WORKSPACE}/checkpoints/${MODEL}}"
EPOCHS="${STRG_EPOCHS:-3}"

echo "==================================================================="
echo "strg fine-tune — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  model:      $MODEL"
echo "  train:      $TRAIN_DIR"
echo "  val:        $VAL_DIR"
echo "  output:     $OUTPUT_DIR"
echo "  epochs:     $EPOCHS"
echo "==================================================================="

cd "$WORKSPACE"

export HF_HOME="${HF_HOME:-/workspace/.hf-cache}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-/workspace/.uv-cache}"
mkdir -p "$HF_HOME" "$UV_CACHE_DIR"

# ── 1. Install dependencies ─────────────────────────────────────────────────
echo ""
echo "--- [1/3] Installing dependencies ---"
bash scripts/runpod_install_fast.sh server
export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"

VENV_PYTHON=".venv/bin/python"
if [[ ! -f "$VENV_PYTHON" ]]; then
  echo "ERROR: venv not found after install" >&2; exit 1
fi

# Install bitsandbytes and peft for QLoRA
echo "Installing QLoRA dependencies..."
PYTHONUNBUFFERED=1 .venv/bin/uv pip install bitsandbytes peft 2>&1 | tail -5

# ── 2. Generate training data if missing ─────────────────────────────────────
echo ""
echo "--- [2/3] Checking training data ---"
N_TRAIN=$(ls "${TRAIN_DIR}"/*.jpg 2>/dev/null | wc -l || echo 0)
N_VAL=$(ls "${VAL_DIR}"/*.jpg 2>/dev/null | wc -l || echo 0)
echo "  train images: $N_TRAIN"
echo "  val images:   $N_VAL"

if [[ "$N_TRAIN" -eq 0 ]]; then
  echo "No training data found — generating 100 synthetic images..."
  PYTHONUNBUFFERED=1 "$VENV_PYTHON" data/generate_train_data.py --count 100 --seed 42 --out "$TRAIN_DIR"
  N_TRAIN=$(ls "${TRAIN_DIR}"/*.jpg 2>/dev/null | wc -l || echo 0)
  echo "  generated: $N_TRAIN training images"
fi

if [[ "$N_VAL" -eq 0 ]]; then
  echo "No val data found — generating 20 synthetic images..."
  PYTHONUNBUFFERED=1 "$VENV_PYTHON" data/generate_train_data.py --count 20 --seed 99 --out "$VAL_DIR"
  N_VAL=$(ls "${VAL_DIR}"/*.jpg 2>/dev/null | wc -l || echo 0)
  echo "  generated: $N_VAL val images"
fi

if [[ "$N_TRAIN" -eq 0 ]]; then
  echo "ERROR: still no training images in $TRAIN_DIR" >&2; exit 1
fi

# ── 3. Fine-tune ─────────────────────────────────────────────────────────────
echo ""
echo "--- [3/3] Fine-tuning model=$MODEL ---"

if [[ -z "${WANDB_API_KEY:-}" ]]; then
  export WANDB_MODE=disabled
  echo "WANDB_API_KEY not set — W&B logging disabled."
fi

FINETUNE_MODULE="models_server.finetune_${MODEL//-/_}"
echo "Running: python -m $FINETUNE_MODULE"
PYTHONUNBUFFERED=1 "$VENV_PYTHON" -m "$FINETUNE_MODULE" \
  --train-dir "$TRAIN_DIR" \
  --val-dir "$VAL_DIR" \
  --output-dir "$OUTPUT_DIR" \
  --epochs "$EPOCHS"
FINETUNE_EXIT=$?

if [[ $FINETUNE_EXIT -ne 0 ]]; then
  echo "ERROR: fine-tune failed (exit $FINETUNE_EXIT)" >&2
  exit $FINETUNE_EXIT
fi

echo ""
echo "==================================================================="
echo "strg fine-tune complete — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  checkpoint: $OUTPUT_DIR/best"
ls -lh "${OUTPUT_DIR}/best" 2>/dev/null || echo "  (no best checkpoint saved)"
echo "==================================================================="
