# ── GCS bucket for base model weights + LoRA adapter ────────────────

resource "google_storage_bucket" "weights" {
  name     = local.weights_bucket_name
  location = var.weights_bucket_location

  # Single-region for lowest latency same-region downloads (Cloud Run cold start).
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Keep it simple — no lifecycle rules needed for a serving bucket.
}

# ── GCS bucket for user feedback photos + corrected labels ──────────
#
# The /feedback endpoint uploads photo.jpg + ground_truth.json for each
# correction the user submits. This data feeds the W&B → fine-tune loop.
# Auto-deleted after 30 days to keep storage costs near zero.

resource "google_storage_bucket" "feedback" {
  name     = local.feedback_bucket_name
  location = var.weights_bucket_location

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

locals {
  weights_bucket_name = (
    var.weights_bucket_name != ""
    ? var.weights_bucket_name
    : "${var.project}-strg-weights"
  )

  feedback_bucket_name = (
    var.feedback_bucket_name != ""
    ? var.feedback_bucket_name
    : "${var.project}-strg-feedback"
  )
}
