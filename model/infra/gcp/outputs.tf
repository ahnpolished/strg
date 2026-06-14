# ── Project ─────────────────────────────────────────────────────────

output "project" {
  description = "GCP project ID (for GitHub Actions variable)."
  value       = var.project
}

# ── Cloud Run ───────────────────────────────────────────────────────

output "serve_url" {
  description = "HTTPS URL of the Cloud Run serving endpoint."
  value       = google_cloud_run_v2_service.serve.uri
}

output "serve_service_account_email" {
  description = "Service account email used by the Cloud Run service (for IAM debugging)."
  value       = google_service_account.serve.email
}

# ── Storage ─────────────────────────────────────────────────────────

output "weights_bucket_name" {
  description = "GCS bucket holding base model weights and LoRA adapter."
  value       = google_storage_bucket.weights.name
}

output "weights_bucket_url" {
  description = "gs:// URL of the weights bucket."
  value       = "gs://${google_storage_bucket.weights.name}"
}

# ── Artifact Registry ───────────────────────────────────────────────

output "docker_repo_url" {
  description = "Full Artifact Registry Docker repository URL for `docker push`."
  value       = "${var.region}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.serve.name}"
}

# ── Fine-tune VM ────────────────────────────────────────────────────

output "finetune_instance_names" {
  description = "Names of any active fine-tune GCE instances."
  value       = google_compute_instance.finetune[*].name
}

output "finetune_instance_ips" {
  description = "External IPs of any active fine-tune GCE instances."
  value       = google_compute_instance.finetune[*].network_interface[0].access_config[0].nat_ip
}

# ── WIF / GitHub Actions ────────────────────────────────────────────

output "wif_provider_name" {
  description = "Full WIF provider resource name. Set as GitHub secret GCP_WIF_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_actions_sa_email" {
  description = "Service account email for GitHub Actions. Set as GitHub secret GCP_WIF_SA."
  value       = google_service_account.github_actions.email
}
