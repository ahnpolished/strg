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

locals {
  weights_bucket_name = (
    var.weights_bucket_name != ""
    ? var.weights_bucket_name
    : "${var.project}-strg-weights"
  )
}
