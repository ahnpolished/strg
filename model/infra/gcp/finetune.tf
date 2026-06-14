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

  # Startup script: clone repo, install deps, and wait for the user
  # to run training via SSH or a follow-up script.
  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -euo pipefail
    INSTANCE_NAME="strg-finetune-${count.index + 1}"
    ZONE="${var.region}-a"
    echo "[finetune] GCE spot VM '$${INSTANCE_NAME}' booted — ready for training."
    echo "[finetune] GPU:"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "  GPU driver not yet loaded (first boot may need a moment)"
    echo "[finetune] Connect: gcloud compute ssh $${INSTANCE_NAME} --zone=$${ZONE} --project=${var.project}"
  EOT

  depends_on = [google_project_service.compute]
}
