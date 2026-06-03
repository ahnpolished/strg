# Cloudflare Worker — stable URL proxy to RunPod serverless.
#
# Prerequisites:
#   1. Domain managed by Cloudflare
#   2. Cloudflare API token with Account.Workers Scripts Edit permission
#
# Set in .env or export:
#   CLOUDFLARE_API_TOKEN  — Cloudflare API token
#   CLOUDFLARE_ACCOUNT_ID — your Cloudflare account ID
#   CLOUDFLARE_ZONE_ID    — zone ID for your domain (optional, for custom domain)
#
# Usage:
#   cd model/infra/cloudflare
#   terraform init && terraform apply -var "serverless_url=https://api.runpod.ai/v2/{endpoint_id}"

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
  default   = null
}

variable "cloudflare_account_id" {
  type    = string
  default = null
}

variable "serverless_url" {
  type        = string
  description = "Current RunPod serverless endpoint URL (e.g. https://api.runpod.ai/v2/abc123)"
  default     = ""
}

variable "worker_name" {
  type    = string
  default = "strg-api-proxy"
}

variable "custom_domain" {
  type    = string
  default = ""
  description = "Optional: custom domain like strg.ahnpolished.com"
}

variable "zone_id" {
  type    = string
  default = null
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# The Worker script
resource "cloudflare_worker_script" "proxy" {
  account_id  = var.cloudflare_account_id
  name        = var.worker_name
  content     = file("${path.module}/worker.js")

  plain_text_binding {
    name = "SERVERLESS_URL"
    text = var.serverless_url
  }

  # Free tier: 100k requests/day
  usage_model = "standard"
}

# Optional: custom domain route
resource "cloudflare_worker_route" "custom_domain" {
  count       = var.custom_domain != "" && var.zone_id != null ? 1 : 0
  zone_id     = var.zone_id
  pattern     = "${var.custom_domain}/*"
  script_name = cloudflare_worker_script.proxy.name
}

# Output the Worker URL
output "worker_url" {
  value = "https://${cloudflare_worker_script.proxy.name}.${var.cloudflare_account_id}.workers.dev"
}

output "custom_domain" {
  value = var.custom_domain != "" ? "https://${var.custom_domain}" : null
}
