# ── Artifact Registry Docker repository ─────────────────────────────

resource "google_artifact_registry_repository" "serve" {
  project       = var.project
  location      = var.region
  repository_id = var.docker_repo_name
  format        = "DOCKER"

  docker_config {
    immutable_tags = false # allow overwriting "latest" during dev
  }

  depends_on = [google_project_service.artifactregistry]
}
