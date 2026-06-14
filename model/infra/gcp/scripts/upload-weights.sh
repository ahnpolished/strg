#!/bin/bash
# ── Upload base model + LoRA adapter to GCS ─────────────────────────
#
# ONE-TIME setup script. Run once before the first Cloud Run deploy.
#
# What it does:
#   1. Downloads Qwen2-VL-7B-Instruct base weights from HuggingFace (~14 GB)
#   2. Downloads the fine-tuned LoRA adapter from W&B (~20 MB)
#   3. Uploads both to the GCS bucket at gs://<bucket>/weights/
#
# Prerequisites:
#   - gcloud CLI authenticated: gcloud auth application-default login
#   - huggingface_hub installed: pip install huggingface_hub (provides `hf`)
#   - wandb installed and logged in: pip install wandb && wandb login
#   - GCS bucket already created (via terraform apply of storage.tf)
#
# Usage:
#   export GCS_BUCKET="ahnpolished-strg-weights"
#   export WANDB_ENTITY="ahnpolished-ahnpolished"
#   export WANDB_PROJECT="strg-model"
#   bash scripts/upload-weights.sh

set -euo pipefail

GCS_BUCKET="${GCS_BUCKET:?Set GCS_BUCKET to the bucket name}"
WANDB_ENTITY="${WANDB_ENTITY:-ahnpolished-ahnpolished}"
WANDB_PROJECT="${WANDB_PROJECT:-strg-model}"
LORA_ARTIFACT="${LORA_ARTIFACT:-qwen2-vl-lora:latest}"
TMPDIR="${TMPDIR:-/tmp/strg-weights-upload}"
MODEL_ID="Qwen/Qwen2-VL-7B-Instruct"

echo "=== Upload weights to GCS ==="
echo "Bucket:     gs://${GCS_BUCKET}"
echo "Model:      ${MODEL_ID}"
echo "LoRA:       ${WANDB_ENTITY}/${WANDB_PROJECT}/${LORA_ARTIFACT}"
echo "Temp dir:   ${TMPDIR}"
echo ""

rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

# ── 1. Download base model from HuggingFace ─────────────────────────
echo "[1/3] Downloading ${MODEL_ID} from HuggingFace ..."
hf download "$MODEL_ID" \
  --local-dir "${TMPDIR}/Qwen2-VL-7B-Instruct"
echo "  Done: $(du -sh "${TMPDIR}/Qwen2-VL-7B-Instruct" | cut -f1)"

# ── 2. Download LoRA adapter from W&B ───────────────────────────────
echo "[2/3] Downloading LoRA adapter from W&B ..."
uv run python -c "
import wandb, os, shutil
api = wandb.Api()
artifact = api.artifact(
    '${WANDB_ENTITY}/${WANDB_PROJECT}/${LORA_ARTIFACT}',
    type='model'
)
lora_dir = '${TMPDIR}/lora'
artifact_dir = artifact.download(root=lora_dir)
print(f'  Downloaded to {artifact_dir}')
# Count files for verification
files = list(os.walk(lora_dir))
count = sum(1 for _, _, fs in files for _ in fs)
print(f'  {count} files')
"
echo "  Done: $(du -sh "${TMPDIR}/lora" | cut -f1)"

# ── 3. Upload to GCS ────────────────────────────────────────────────
echo "[3/3] Uploading to gs://${GCS_BUCKET}/weights/ ..."
gcloud storage cp -r "${TMPDIR}/Qwen2-VL-7B-Instruct" "gs://${GCS_BUCKET}/weights/"
gcloud storage cp -r "${TMPDIR}/lora" "gs://${GCS_BUCKET}/weights/"
echo "  Done."

# ── Cleanup ─────────────────────────────────────────────────────────
rm -rf "$TMPDIR"
echo ""
echo "=== Upload complete ==="
echo "Base model:  gs://${GCS_BUCKET}/weights/Qwen2-VL-7B-Instruct/"
echo "LoRA:        gs://${GCS_BUCKET}/weights/lora/"
echo ""
echo "Now build and push the serving image:"
echo "  cd model && docker build -f Dockerfile -t <repo-url>/serve:latest ."
echo "  docker push <repo-url>/serve:latest"
