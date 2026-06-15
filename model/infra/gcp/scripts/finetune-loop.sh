#!/bin/bash
# ── GCE Spot VM fine-tuning startup script ──────────────────────────
#
# Expected metadata keys (set by trigger_finetune.py or `gcloud`):
#   finetune-model             Model to fine-tune (moondream|phi35|qwen2-vl)
#   feedback-artifact-version  W&B artifact version (e.g. "v7")
#   repo-commit                Git commit SHA to checkout
#
# Flow:
#   1. Wait for GPU driver to load
#   2. Clone repo at specified commit
#   3. Install uv + Python dependencies
#   4. Pull base model weights from GCS
#   5. Pull feedback data from GCS → convert to training format
#   6. Run fine-tune script for selected model
#   7. Upload checkpoint to GCS + W&B
#   8. Set finetune-status=done in metadata
#   9. Self-terminate
#
# Budget: g2-standard-4 spot VM with L4 ≈ $0.25/hr. Training takes
# 1-3 hrs depending on model and data size → $0.25-$0.75 per run.

set -euo pipefail

# ── Metadata helpers ─────────────────────────────────────────────────
# Reads VM metadata — works inside GCE VMs via the metadata server.
metadata_value() {
  curl -s -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" \
    2>/dev/null || echo ""
}

report_status() {
  local status="$1"
  echo "[finetune] Status: $status"
  gcloud compute instances add-metadata \
    "$(hostname)" \
    --zone="$(metadata_value zone)" \
    --metadata="finetune-status=$status" \
    2>/dev/null || true
}

fail() {
  echo "[finetune] FAILED: $1"
  report_status "failed"
  exit 1
}

# ── Configuration ────────────────────────────────────────────────────
MODEL="${1:-$(metadata_value finetune-model)}"
FEEDBACK_VERSION="${2:-$(metadata_value feedback-artifact-version)}"
REPO_COMMIT="${3:-$(metadata_value repo-commit)}"
PROJECT="${GCP_PROJECT:-ahnpolished}"
ZONE="${GCE_ZONE:-us-central1-a}"

# Validate required metadata
if [ -z "$MODEL" ]; then
  fail "finetune-model metadata not set"
fi
if [ -z "$REPO_COMMIT" ]; then
  REPO_COMMIT="main"
  echo "[finetune] Using default repo-commit=$REPO_COMMIT"
fi

WEIGHTS_BUCKET="${GCS_WEIGHTS_BUCKET:-ahnpolished-strg-weights}"
FEEDBACK_BUCKET="${GCS_FEEDBACK_BUCKET:-ahnpolished-strg-feedback}"
REPO_URL="https://github.com/ahnpolished/strg.git"
WORK_DIR="/tmp/strg-finetune"
DATA_DIR="$WORK_DIR/data/feedback-train"

echo "=== strg finetune-loop ==="
echo "Model:            $MODEL"
echo "Feedback version: ${FEEDBACK_VERSION:-N/A}"
echo "Repo commit:      $REPO_COMMIT"
echo "Weights bucket:   $WEIGHTS_BUCKET"
echo "Feedback bucket:  $FEEDBACK_BUCKET"
echo "Work dir:         $WORK_DIR"
echo ""

# ── 0. Wait for GPU ─────────────────────────────────────────────────
echo "[finetune] Waiting for GPU driver..."
for i in $(seq 1 30); do
  if nvidia-smi -L >/dev/null 2>&1; then
    echo "[finetune] GPU ready: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)"
    break
  fi
  sleep 10
done
if ! nvidia-smi -L >/dev/null 2>&1; then
  fail "GPU driver not loaded after 5 minutes"
fi

# ── 1. Clone repo ───────────────────────────────────────────────────
echo "[finetune] Cloning repo at commit $REPO_COMMIT ..."
rm -rf "$WORK_DIR"
git clone "$REPO_URL" "$WORK_DIR"
cd "$WORK_DIR"
git checkout "$REPO_COMMIT"
cd model

# ── 2. Install dependencies ─────────────────────────────────────────
echo "[finetune] Installing uv + Python dependencies..."
if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

uv python install 3.12
# Install torch with CUDA first (the pytorch base image may already have it,
# but we ensure compatibility)
uv sync --package models-server --frozen --no-dev || {
  echo "[finetune] uv sync failed — trying without --frozen..."
  uv sync --package models-server --no-dev
}

# ── 3. Pull base model weights from GCS ─────────────────────────────
echo "[finetune] Pulling base model weights from GCS..."
mkdir -p /tmp/model

case "$MODEL" in
  qwen2-vl)
    MODEL_WEIGHTS_DIR="/tmp/model/Qwen2-VL-7B-Instruct"
    gsutil -m cp -r "gs://${WEIGHTS_BUCKET}/weights/Qwen2-VL-7B-Instruct/*" "$MODEL_WEIGHTS_DIR/"
    MODEL_HF_ID="Qwen/Qwen2-VL-7B-Instruct"
    ;;

  phi35)
    # Phi-3.5 downloads automatically from HuggingFace if not cached.
    # Pre-download to /tmp/hf-cache to speed up fine-tuning.
    export HF_HOME="/tmp/hf-cache"
    MODEL_HF_ID="microsoft/Phi-3.5-vision-instruct"
    echo "[finetune] Phi-3.5 will download from HF on first use (cached in /tmp/hf-cache)."
    # Optionally pull from GCS if available:
    gsutil -m cp -r "gs://${WEIGHTS_BUCKET}/weights/Phi-3.5-vision-instruct/*" "$HF_HOME/" 2>/dev/null || true
    ;;

  moondream)
    export HF_HOME="/tmp/hf-cache"
    MODEL_HF_ID="vikhyatk/moondream2"
    echo "[finetune] Moondream2 will download from HF (small, ~4 GB)."
    # Optionally pull from GCS:
    gsutil -m cp -r "gs://${WEIGHTS_BUCKET}/weights/moondream2/*" "$HF_HOME/" 2>/dev/null || true
    ;;

  *)
    fail "Unknown model: $MODEL (choose moondream|phi35|qwen2-vl)"
    ;;
esac

# ── 4. Pull feedback data from GCS → training format ──────────
echo "[finetune] Pulling feedback data from GCS..."
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

FEEDBACK_GS="gs://${FEEDBACK_BUCKET}/feedback/"
gsutil -m cp -r "$FEEDBACK_GS" "/tmp/feedback-raw/" 2>/dev/null || {
  echo "[finetune] WARNING: No feedback data found in GCS. Using existing data/train."
}

# Convert feedback entries into training format (photo.jpg + ground_truth.json pairs)
if [ -d "/tmp/feedback-raw/feedback" ]; then
  echo "[finetune] Converting feedback to training format..."
  for subdir in /tmp/feedback-raw/feedback/*/; do
    fid=$(basename "$subdir")
    src_jpg="$subdir/${fid}.jpg"
    src_json="$subdir/${fid}.json"

    if [ -f "$src_jpg" ] && [ -f "$src_json" ]; then
      # Extract entries from feedback JSON and create ground_truth.json
      python3 -c "
import json, sys
meta = json.load(open('$src_json'))
# Write only the corrected entries as ground truth
gt = {'entries': meta['entries']}
json.dump(gt, open('$DATA_DIR/${fid}.json', 'w'), indent=2)
"
      cp "$src_jpg" "$DATA_DIR/${fid}.jpg"
    fi
  done
  echo "[finetune]   Converted $(ls $DATA_DIR/*.jpg 2>/dev/null | wc -l) training samples"
fi

# Fall back to synthetic data if not enough feedback samples
TRAIN_COUNT=$(ls "$DATA_DIR"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
if [ "$TRAIN_COUNT" -lt 5 ]; then
  echo "[finetune] Only $TRAIN_COUNT feedback samples — supplementing with synthetic data."
  if [ -d "data/train" ]; then
    cp data/train/*.jpg "$DATA_DIR/" 2>/dev/null || true
    cp data/train/*.json "$DATA_DIR/" 2>/dev/null || true
  fi
  # Generate more synthetic if needed
  if [ "$(ls "$DATA_DIR"/*.jpg 2>/dev/null | wc -l | tr -d ' ')" -lt 10 ]; then
    echo "[finetune] Generating synthetic training data..."
    uv run python data/generate_synthetic.py --output-dir "$DATA_DIR" --count 20 2>/dev/null || true
  fi
fi

TRAIN_COUNT=$(ls "$DATA_DIR"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "[finetune] Training dataset: $TRAIN_COUNT samples"

# ── 5. Split into train/val ─────────────────────────────────────────
VAL_DIR="$WORK_DIR/data/val"
rm -rf "$VAL_DIR"
mkdir -p "$VAL_DIR"

# Move ~20% of samples to val (up to 5)
VAL_COUNT=$(( TRAIN_COUNT / 5 ))
[ "$VAL_COUNT" -gt 5 ] && VAL_COUNT=5
[ "$VAL_COUNT" -lt 1 ] && VAL_COUNT=1

for f in $(ls "$DATA_DIR"/*.jpg 2>/dev/null | head -n "$VAL_COUNT"); do
  base=$(basename "$f" .jpg)
  mv "$DATA_DIR/${base}.jpg" "$VAL_DIR/" 2>/dev/null || true
  mv "$DATA_DIR/${base}.json" "$VAL_DIR/" 2>/dev/null || true
done

TRAIN_COUNT=$(ls "$DATA_DIR"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
VAL_COUNT_REAL=$(ls "$VAL_DIR"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "[finetune] train=$TRAIN_COUNT val=$VAL_COUNT_REAL"

# ── 6. Run fine-tune ────────────────────────────────────────────────
echo "[finetune] Starting fine-tuning for '$MODEL'..."
report_status "training"

CHECKPOINT_DIR="$WORK_DIR/checkpoints/$MODEL"
mkdir -p "$CHECKPOINT_DIR"

case "$MODEL" in
  qwen2-vl)
    uv run python -m models_server.finetune_qwen2_vl \
      --train-dir "$DATA_DIR" \
      --val-dir "$VAL_DIR" \
      --output-dir "$CHECKPOINT_DIR" \
      --epochs 3 \
      --lr 2e-4 \
      --batch-size 1 \
      --grad-accum 8 \
      --patience 5 \
      || fail "Fine-tuning failed for qwen2-vl"
    ;;

  phi35)
    uv run python -m models_local.finetune_phi35 \
      --train-dir "$DATA_DIR" \
      --val-dir "$VAL_DIR" \
      --output-dir "$CHECKPOINT_DIR" \
      --epochs 5 \
      --lr 2e-4 \
      --batch-size 2 \
      --grad-accum 8 \
      --patience 3 \
      || fail "Fine-tuning failed for phi35"
    ;;

  moondream)
    # Moondream fine-tuning needs a dedicated script — use a simplified approach
    # that fine-tunes the full model (small enough, ~4GB, fits on L4)
    echo "[finetune] Moondream2 fine-tune script"
    uv run python scripts/finetune_moondream.py \
      --train-dir "$DATA_DIR" \
      --val-dir "$VAL_DIR" \
      --output-dir "$CHECKPOINT_DIR" \
      --epochs 5 \
      --lr 1e-4 \
      --batch-size 4 \
      --grad-accum 4 \
      --patience 3 \
      2>/dev/null || fail "Fine-tuning failed for moondream"
    ;;
esac

echo "[finetune] Fine-tuning complete!"

# ── 7. Upload checkpoint to GCS ─────────────────────────────────────
echo "[finetune] Uploading checkpoint to GCS..."

case "$MODEL" in
  qwen2-vl)
    CKPT_SRC="$CHECKPOINT_DIR/best"
    GCS_DST="gs://${WEIGHTS_BUCKET}/weights/lora/"
    ;;
  phi35)
    CKPT_SRC="$CHECKPOINT_DIR/best"
    GCS_DST="gs://${WEIGHTS_BUCKET}/weights/phi35-lora/"
    ;;
  moondream)
    CKPT_SRC="$CHECKPOINT_DIR/best"
    GCS_DST="gs://${WEIGHTS_BUCKET}/weights/moondream-lora/"
    ;;
esac

if [ -d "$CKPT_SRC" ]; then
  gsutil -m cp -r "$CKPT_SRC/*" "$GCS_DST"
  echo "[finetune] Checkpoint uploaded to $GCS_DST"
else
  # Fall back to any checkpoint
  CKPT_FALLBACK=$(ls -d "$CHECKPOINT_DIR"/*/ 2>/dev/null | head -1)
  if [ -n "$CKPT_FALLBACK" ]; then
    gsutil -m cp -r "${CKPT_FALLBACK}*" "$GCS_DST"
    echo "[finetune] Checkpoint (fallback) uploaded to $GCS_DST"
  else
    echo "[finetune] WARNING: No checkpoint found to upload."
  fi
fi

# ── 8. Upload to W&B as artifact ────────────────────────────────────
echo "[finetune] Uploading to W&B..."
if [ -d "$CKPT_SRC" ]; then
  uv run python scripts/upload_checkpoint.py \
    --checkpoint-dir "$CKPT_SRC" \
    --model "$MODEL" \
    --notes "Automated fine-tune loop from feedback (commit $REPO_COMMIT)" \
    || echo "[finetune] W&B upload failed (non-fatal)"
fi

# ── 9. Self-terminate ───────────────────────────────────────────────
echo "[finetune] Training complete. Self-terminating in 30s..."
report_status "done"

# Clean up GCS feedback that was processed (move to archive)
# gsutil -m mv "gs://${FEEDBACK_BUCKET}/feedback/" "gs://${FEEDBACK_BUCKET}/feedback-archive/$(date +%Y%m%d-%H%M%S)/" 2>/dev/null || true

sleep 30

INSTANCE_NAME="$(hostname)"
ZONE_NAME="$(metadata_value zone)"
echo "[finetune] Deleting instance $INSTANCE_NAME in $ZONE_NAME..."
gcloud compute instances delete "$INSTANCE_NAME" \
  --zone="$ZONE_NAME" \
  --project="$PROJECT" \
  --quiet \
  2>/dev/null || true

echo "[finetune] Done."
