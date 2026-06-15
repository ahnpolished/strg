# ── GCE spot VM for future QLoRA fine-tuning (disabled by default) ──
#
# count = var.finetune_instance_count defaults to 0.
# When fine-tuning is needed, set count to 1, apply, run the training,
# then set count back to 0 and apply again.
#
# Same discipline as model/infra/runpod/: apply → run → destroy.
#
# Machine: g2-standard-4 (4 vCPU, 16 GB RAM, 1× NVIDIA L4 24 GB)
# Provisioning model: SPOT (preemptible, ~60-80% cheaper)
#
# Uses Deep Learning VM image with PyTorch + CUDA pre-installed.

resource "google_compute_instance" "finetune" {
  count = var.finetune_instance_count

  name         = "strg-finetune-${count.index + 1}"
  machine_type = var.finetune_machine_type
  zone         = "${var.region}-a"
  project      = var.project

  # Spot provisioning — cheap but can be terminated at any time.
  scheduling {
    provisioning_model          = "SPOT"
    automatic_restart           = false
    instance_termination_action = "STOP"
  }

  boot_disk {
    initialize_params {
      image = "projects/deeplearning-platform-release/global/images/family/pytorch-latest-gpu-ubuntu-2204"
      size  = var.finetune_boot_disk_size_gb
      type  = "pd-ssd"
    }
  }

  guest_accelerator {
    type  = "nvidia-l4"
    count = 1
  }

  network_interface {
    network = "default"
    access_config {
      # Public IP for SSH access
    }
  }

  # Cloud-platform scope gives the VM access to GCS, Artifact Registry, etc.
  service_account {
    scopes = ["cloud-platform"]
  }

  # ── Automated fine-tuning loop startup script ────────────────────────
  #
  # 1. Clone repo + install uv + Python deps
  # 2. Pull feedback data from GCS feedback bucket
  # 3. Download base model weights from GCS
  # 4. Run fine-tuning for the configured model
  # 5. Push checkpoint to GCS weights bucket
  # 6. Log result to W&B
  # 7. Auto-terminate the VM
  #
  # Set STRG_FINETUNE_MODEL in VM metadata to choose the model.
  # The VM self-destructs after training (success or failure) to avoid
  # idle GPU billing.
  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -euo pipefail

    # ── Config from VM metadata / Terraform variables ──────────────────
    INSTANCE_NAME="strg-finetune-${count.index + 1}"
    ZONE="${var.region}-a"
    PROJECT="${var.project}"
    WEIGHTS_BUCKET="${local.weights_bucket_name}"
    FEEDBACK_BUCKET="${local.feedback_bucket_name}"
    FINETUNE_MODEL="$${STRG_FINETUNE_MODEL:-${var.finetune_model}}"

    LOG_FILE="/tmp/finetune-$${INSTANCE_NAME}.log"
    exec > >(tee -a "$${LOG_FILE}") 2>&1

    echo "============================================"
    echo "[finetune] Boot: $(date -u)"
    echo "[finetune] Instance: $${INSTANCE_NAME}"
    echo "[finetune] Model:    $${FINETUNE_MODEL}"
    echo "[finetune] Zone:     $${ZONE}"
    echo "============================================"

    # ── Wait for GPU ──────────────────────────────────────────────────
    echo "[finetune] Waiting for GPU driver..."
    for i in $(seq 1 30); do
      if nvidia-smi >/dev/null 2>&1; then break; fi
      sleep 10
    done
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || {
      echo "[finetune] ERROR: GPU not available after 5 min. Terminating."
      gcloud compute instances delete "$${INSTANCE_NAME}" --zone="$${ZONE}" --project="$${PROJECT}" --quiet
      exit 1
    }
    echo "[finetune] GPU ready."

    # ── Clone repo ────────────────────────────────────────────────────
    REPO_DIR="/home/$${USER:-root}/strg"
    if [ ! -d "$${REPO_DIR}" ]; then
      echo "[finetune] Cloning ahnpolished/strg..."
      git clone https://github.com/ahnpolished/strg.git "$${REPO_DIR}"
    else
      echo "[finetune] Repo exists — pulling latest..."
      cd "$${REPO_DIR}" && git pull origin main
    fi
    cd "$${REPO_DIR}/model"

    # ── Install uv + Python deps ──────────────────────────────────────
    if ! command -v uv &>/dev/null; then
      echo "[finetune] Installing uv..."
      curl -LsSf https://astral.sh/uv/install.sh | sh
      export PATH="$${HOME}/.local/bin:$${PATH}"
    fi
    echo "[finetune] Installing Python dependencies..."
    uv sync --package models-server --frozen 2>&1 | tail -5

    # ── Pull feedback data from GCS ────────────────────────────────────
    FEEDBACK_DIR="data/feedback"
    mkdir -p "$${FEEDBACK_DIR}"
    echo "[finetune] Pulling feedback from gs://$${FEEDBACK_BUCKET}/feedback/ ..."
    gsutil -m cp -r "gs://$${FEEDBACK_BUCKET}/feedback/*" "$${FEEDBACK_DIR}/" 2>/dev/null || {
      echo "[finetune] WARNING: No feedback data found in bucket. Using existing train/val data."
    }
    FEEDBACK_COUNT=$(find "$${FEEDBACK_DIR}" -name 'ground_truth.json' | wc -l)
    echo "[finetune] Feedback samples pulled: $${FEEDBACK_COUNT}"

    # ── Download base model weights from GCS ───────────────────────────
    MODEL_DIR="/tmp/model"
    mkdir -p "$${MODEL_DIR}"

    case "$${FINETUNE_MODEL}" in
      moondream)
        echo "[finetune] Moondream2 is small — using HuggingFace cache."
        export HF_HOME="$${MODEL_DIR}/hf-cache"
        ;;
      phi35)
        echo "[finetune] Downloading Phi-3.5-Vision weights..."
        if ! gsutil -q stat "gs://$${WEIGHTS_BUCKET}/weights/Phi-3.5-vision-instruct/*" 2>/dev/null; then
          echo "[finetune] Weights not in GCS — will download from HuggingFace."
        else
          gsutil -m cp -r "gs://$${WEIGHTS_BUCKET}/weights/Phi-3.5-vision-instruct/*" "$${MODEL_DIR}/Phi-3.5-vision-instruct/"
        fi
        export STRG_PHI35_MODEL_PATH="$${MODEL_DIR}/Phi-3.5-vision-instruct"
        ;;
      qwen2-vl)
        echo "[finetune] Downloading Qwen2-VL-7B weights..."
        gsutil -m cp -r "gs://$${WEIGHTS_BUCKET}/weights/Qwen2-VL-7B-Instruct/*" "$${MODEL_DIR}/Qwen2-VL-7B-Instruct/"
        export STRG_QWEN_MODEL_PATH="$${MODEL_DIR}/Qwen2-VL-7B-Instruct"
        ;;
      *)
        echo "[finetune] ERROR: Unknown model '$${FINETUNE_MODEL}'. Terminating."
        gcloud compute instances delete "$${INSTANCE_NAME}" --zone="$${ZONE}" --project="$${PROJECT}" --quiet
        exit 1
        ;;
    esac

    # ── Run fine-tuning ────────────────────────────────────────────────
    echo "[finetune] Starting fine-tuning for '$${FINETUNE_MODEL}'..."
    TRAIN_DIR="data/train"
    VAL_DIR="data/val"
    OUTPUT_DIR="checkpoints/$${FINETUNE_MODEL}-$$(date +%Y%m%d-%H%M%S)"

    # Merge feedback into train dir if we have any
    if [ "$${FEEDBACK_COUNT}" -gt 0 ]; then
      echo "[finetune] Merging $${FEEDBACK_COUNT} feedback samples into training data..."
      mkdir -p "$${TRAIN_DIR}"
      for fb_dir in "$${FEEDBACK_DIR}"/feedback_*; do
        [ -d "$${fb_dir}" ] || continue
        cp "$${fb_dir}"/photo.jpg "$${TRAIN_DIR}/fb_$$(basename $$fb_dir).jpg" 2>/dev/null || true
        cp "$${fb_dir}"/ground_truth.json "$${TRAIN_DIR}/fb_$$(basename $$fb_dir).json" 2>/dev/null || true
      done
    fi

    FT_EXIT=0
    case "$${FINETUNE_MODEL}" in
      moondream)
        uv run python -m models_server.finetune_moondream \
          --train-dir "$${TRAIN_DIR}" --val-dir "$${VAL_DIR}" \
          --output-dir "$${OUTPUT_DIR}" --epochs 3 || FT_EXIT=1
        ;;
      phi35)
        uv run python -m models_local.finetune_phi35 \
          --train-dir "$${TRAIN_DIR}" --val-dir "$${VAL_DIR}" \
          --output-dir "$${OUTPUT_DIR}" --epochs 5 || FT_EXIT=1
        ;;
      qwen2-vl)
        uv run python -m models_server.finetune_qwen2_vl \
          --train-dir "$${TRAIN_DIR}" --val-dir "$${VAL_DIR}" \
          --output-dir "$${OUTPUT_DIR}" --epochs 3 || FT_EXIT=1
        ;;
    esac

    # ── Push checkpoint to GCS ─────────────────────────────────────────
    if [ "$${FT_EXIT}" -eq 0 ] && [ -d "$${OUTPUT_DIR}/best" ]; then
      echo "[finetune] Pushing checkpoint to gs://$${WEIGHTS_BUCKET}/weights/$${FINETUNE_MODEL}-lora/ ..."
      gsutil -m cp -r "$${OUTPUT_DIR}/best/*" "gs://$${WEIGHTS_BUCKET}/weights/$${FINETUNE_MODEL}-lora/"
      echo "[finetune] Checkpoint uploaded. New LoRA ready for serving."
    else
      echo "[finetune] WARNING: Fine-tuning failed or no checkpoint produced."
    fi

    # ── Auto-terminate ─────────────────────────────────────────────────
    echo "[finetune] Done at $(date -u). Self-terminating in 30 seconds..."
    sleep 30
    gcloud compute instances delete "$${INSTANCE_NAME}" \
      --zone="$${ZONE}" --project="$${PROJECT}" --quiet || true
  EOT

  depends_on = [google_project_service.compute]
}
