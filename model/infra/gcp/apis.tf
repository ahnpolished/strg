# ── Required APIs for GPU serving ───────────────────────────────────
# compute.googleapis.com is already enabled on project ahnpolished.
# We enable the three additional APIs needed for Cloud Run serving.

resource "google_project_service" "run" {
  project            = var.project
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  project            = var.project
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  project            = var.project
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

# Needed for the fine-tune GCE module (optional — harmless if already enabled)
resource "google_project_service" "compute" {
  project            = var.project
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

# billingbudgets API for the billing budget (budget.tf). This API requires
# a quota project when using user ADC. If you still get a 403, run:
#   gcloud auth application-default set-quota-project ahnpolished
resource "google_project_service" "billingbudgets" {
  project            = var.project
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}

# monitoring API for the budget notification channel (budget.tf)
resource "google_project_service" "monitoring" {
  project            = var.project
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}
