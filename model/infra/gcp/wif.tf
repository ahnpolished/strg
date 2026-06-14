# ── Workload Identity Federation for GitHub Actions ─────────────────
#
# Lets GitHub Actions authenticate to GCP without storing a service
# account key. The OIDC provider maps GitHub's token claims to GCP
# attributes, and the IAM binding restricts impersonation to a specific
# repository.
#
# After terraform apply, run scripts/gh-set-secrets.sh to push the
# provider name + SA email into GitHub Actions secrets automatically.

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions pool"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Actions OIDC"

  attribute_mapping = {
    "google.subject" = "assertion.sub"
    "attribute.gh"   = "assertion.repository"
  }

  attribute_condition = "assertion.repository.startsWith(\"${var.github_repo}\")"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# ── Service account for GitHub Actions CI/CD ────────────────────────

resource "google_service_account" "github_actions" {
  project      = var.project
  account_id   = "github-actions"
  display_name = "GitHub Actions CI/CD"
}

# Allow GitHub Actions to impersonate this SA — restricted to the
# specific repository via attribute.repository.
resource "google_service_account_iam_member" "github_wif" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.gh/${var.github_repo}"
}

# ── Roles for the GitHub Actions SA ─────────────────────────────────

# Push Docker images to Artifact Registry
resource "google_project_iam_member" "github_ar_writer" {
  project = var.project
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# Deploy new revisions to Cloud Run
resource "google_project_iam_member" "github_run_admin" {
  project = var.project
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}
