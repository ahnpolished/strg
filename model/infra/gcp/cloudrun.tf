# ── Cloud Run GPU serving service ────────────────────────────────────
#
# min-instances=0 is non-negotiable — min-instances=1 on an L4 is ~$17/day.
# This service is the REAL test of Cloud Run GPU quota on project ahnpolished.
# If quota is 0, the apply will fail and we fall back to the GCE spot VM module.
#
# Resource limits: Cloud Run GPU requires 8 vCPU minimum to request 32 GiB
# memory (the ratio is 1:4, and we need 32 GiB for the 14 GB model download
# into /tmp plus Python runtime).

# Service account for the Cloud Run instance
resource "google_service_account" "serve" {
  account_id   = "strg-serve"
  display_name = "strg-model Cloud Run serving account"
  project      = var.project
}

# Grant read access to the weights bucket
resource "google_storage_bucket_iam_member" "serve_read_weights" {
  bucket = google_storage_bucket.weights.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.serve.email}"
}

# Grant write access to the feedback bucket (for /feedback endpoint uploads)
resource "google_storage_bucket_iam_member" "serve_write_feedback" {
  bucket = google_storage_bucket.feedback.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.serve.email}"
}

# Grant read access to the feedback bucket (for fine-tuning data pull)
resource "google_storage_bucket_iam_member" "serve_read_feedback" {
  bucket = google_storage_bucket.feedback.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.serve.email}"
}

# Grant Artifact Registry read access for container image pull
resource "google_artifact_registry_repository_iam_member" "serve_read_images" {
  project    = var.project
  location   = var.region
  repository = google_artifact_registry_repository.serve.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.serve.email}"
}

# The GPU Cloud Run service
resource "google_cloud_run_v2_service" "serve" {
  name                = var.serve_name
  location            = var.region
  project             = var.project
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.serve.email

    # Request an L4 GPU node — this is a SEPARATE quota from Compute Engine.
    node_selector {
      accelerator = "nvidia-l4"
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.serve.name}/serve:${var.serve_image_tag}"

      resources {
        limits = {
          cpu              = "8"
          memory           = "32Gi"
          "nvidia.com/gpu" = "1"
        }
      }

      env {
        name  = "GCS_BUCKET"
        value = google_storage_bucket.weights.name
      }
      env {
        name  = "STRG_MODEL"
        value = var.default_model
      }
      env {
        name  = "STRG_GCS_MOUNT"
        value = "/mnt/gcs"
      }
      # ── Qwen2-VL-7B (legacy, high quality, ~130s) ──
      env {
        name  = "STRG_QWEN_MODEL_PATH"
        value = "/tmp/model/Qwen2-VL-7B-Instruct"
      }
      env {
        name  = "STRG_QWEN_LORA_CHECKPOINT"
        value = "/tmp/model/lora"
      }
      env {
        name  = "STRG_QWEN_LOAD_IN_4BIT"
        value = var.load_in_4bit ? "true" : "false"
      }
      # ── Phi-3.5-Vision (3.8B, ~20-35s, best accuracy/speed) ──
      env {
        name  = "STRG_PHI35_MODEL_PATH"
        value = "/tmp/model/Phi-3.5-vision-instruct"
      }
      env {
        name  = "STRG_PHI35_LOAD_IN_4BIT"
        value = "true"
      }
      env {
        name  = "STRG_PHI35_LORA_CHECKPOINT"
        value = "/tmp/model/phi35-lora"
      }
      # ── Moondream2 (1.8B, ~3-8s, fastest) ──
      env {
        name  = "STRG_MOONDREAM_MODEL_PATH"
        value = "/tmp/model/moondream2"
      }
      # ── Shared ──
      env {
        name  = "HF_HOME"
        value = "/tmp/hf-cache"
      }
      env {
        name  = "TORCH_COMPILE"
        value = "0"
      }

      # Mount GCS feedback bucket as a filesystem for predict images & feedback.
      # The service account has objectViewer + objectCreator on this bucket.
      volume_mounts {
        name       = "gcs-data"
        mount_path = "/mnt/gcs"
      }

      # Generous startup probe — the container downloads ~14 GB from GCS
      # on every cold start (~1-2 min), then uvicorn starts.
      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 10
        period_seconds        = 30
        failure_threshold     = 10 # 10 × 30 s = 5 min total
        tcp_socket {
          port = 8080
        }
      }
    }

    # GCS bucket mounted as a filesystem (gcsfuse).
    # Predict images → /mnt/gcs/predict/
    # Feedback data   → /mnt/gcs/feedback/
    volumes {
      name = "gcs-data"
      gcs {
        bucket    = google_storage_bucket.feedback.name
        read_only = false
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    # Max one concurrent request — GPU inference is sequential.
    max_instance_request_concurrency = 1

    # Disable zonal redundancy — we only have quota for single-zone GPU.
    # Without this flag, Cloud Run requires multi-zone GPU quota.
    gpu_zonal_redundancy_disabled = true
  }

  depends_on = [
    google_project_service.run,
    google_artifact_registry_repository.serve,
  ]
}

# Make the service publicly invokable
resource "google_cloud_run_v2_service_iam_member" "public" {
  project  = var.project
  location = google_cloud_run_v2_service.serve.location
  name     = google_cloud_run_v2_service.serve.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
