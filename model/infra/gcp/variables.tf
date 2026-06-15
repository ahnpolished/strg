# ── Project / region ───────────────────────────────────────────────

variable "project" {
  description = "GCP project ID."
  type        = string
  default     = "ahnpolished"
}

variable "region" {
  description = "GCP region for all resources."
  type        = string
  default     = "us-central1"
}

# ── Serving ─────────────────────────────────────────────────────────

variable "serve_name" {
  description = "Name prefix for the Cloud Run serving service."
  type        = string
  default     = "strg-serve"
}

variable "serve_image_tag" {
  description = "Docker image tag to deploy on Cloud Run."
  type        = string
  default     = "latest"
}

variable "load_in_4bit" {
  description = "Load the base Qwen2-VL-7B model in 4-bit (bitsandbytes NF4). Saves VRAM and speeds cold starts. Set false to use full bfloat16 on GPUs with >24 GB."
  type        = bool
  default     = true
}

# ── Storage ─────────────────────────────────────────────────────────

variable "weights_bucket_name" {
  description = "GCS bucket name for base weights and LoRA adapter. Leave empty to auto-generate from project."
  type        = string
  default     = ""
}

variable "weights_bucket_location" {
  description = "GCS bucket location. Must be a single-region location matching var.region for fastest cold-start downloads."
  type        = string
  default     = "US-CENTRAL1"
}

# ── Artifact Registry ───────────────────────────────────────────────

variable "docker_repo_name" {
  description = "Artifact Registry Docker repository name."
  type        = string
  default     = "strg-serve"
}

# ── Budget ──────────────────────────────────────────────────────────

variable "budget_amount" {
  description = "Monthly billing budget in USD. Only alerts — does not stop spend."
  type        = number
  default     = 10
}

variable "budget_alert_thresholds" {
  description = "Alert thresholds as fractions of the budget amount."
  type        = list(number)
  default     = [0.5, 0.8, 1.0] # $5, $8, $10
}

variable "budget_email" {
  description = "Email address for billing budget alerts."
  type        = string
  default     = "stahn1995@gmail.com"
}

# ── GitHub Actions CI/CD (WIF) ──────────────────────────────────────

variable "github_repo" {
  description = "GitHub repository in 'org/repo' format for WIF OIDC binding (e.g. 'myorg/strg'). Required so only your repo can impersonate the CI/CD service account."
  type        = string
}

# ── Model selection ─────────────────────────────────────────────────

variable "default_model" {
  description = "Default model to serve on Cloud Run (moondream | phi35 | qwen2-vl)."
  type        = string
  default     = "qwen2-vl"

  validation {
    condition     = contains(["moondream", "phi35", "qwen2-vl"], var.default_model)
    error_message = "default_model must be one of: moondream, phi35, qwen2-vl."
  }
}

variable "finetune_model" {
  description = "Model to fine-tune on the spot VM (moondream | phi35 | qwen2-vl)."
  type        = string
  default     = "moondream"

  validation {
    condition     = contains(["moondream", "phi35", "qwen2-vl"], var.finetune_model)
    error_message = "finetune_model must be one of: moondream, phi35, qwen2-vl."
  }
}

# ── Fine-tune VM (disabled by default) ──────────────────────────────

variable "finetune_instance_count" {
  description = "Number of GCE spot VMs for fine-tuning. Keep 0 unless actively running a training loop. Apply -> train -> destroy, same discipline as RunPod pods."
  type        = number
  default     = 0

  validation {
    condition     = var.finetune_instance_count >= 0 && floor(var.finetune_instance_count) == var.finetune_instance_count
    error_message = "finetune_instance_count must be a non-negative integer."
  }
}

variable "finetune_machine_type" {
  description = "GCE machine type for fine-tuning VMs (1x L4 GPU)."
  type        = string
  default     = "g2-standard-4"
}

variable "finetune_boot_disk_size_gb" {
  description = "Boot disk size in GB for fine-tune VMs."
  type        = number
  default     = 100
}

# ── Feedback storage ────────────────────────────────────────────────

variable "feedback_bucket_name" {
  description = "GCS bucket name for user feedback (photos + corrected labels). Leave empty to auto-generate from project."
  type        = string
  default     = ""
}
