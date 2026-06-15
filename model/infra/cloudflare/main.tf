# Cloudflare Worker — stable URL proxy to the backend (Cloud Run or RunPod serverless).
#
# Prerequisites:
#   1. Domain managed by Cloudflare
#   2. Cloudflare API token with Account.Workers Scripts Edit permission
#      (and Zone.DNS Edit + Zone.Workers Routes Edit if using custom_domain)
#
# Set in .env or export:
#   CLOUDFLARE_API_TOKEN  — Cloudflare API token
#   CLOUDFLARE_ACCOUNT_ID — your Cloudflare account ID
#
# Usage:
#   cd model/infra/cloudflare
#   terraform init && terraform apply -var "backend_url=https://strg-serve-xxxx-uc.a.run.app"

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

variable "backend_url" {
  type        = string
  description = "Current backend URL to proxy to (e.g. Cloud Run service URL or RunPod serverless endpoint)"
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
  module      = true

  plain_text_binding {
    name = "BACKEND_URL"
    text = var.backend_url
  }
}

# DNS-only CNAME pointing directly at Cloud Run's domain-mapping frontend.
# Proxy is OFF (Cloudflare not in the path) so Google can issue the TLS cert
# and so requests aren't subject to Cloudflare's ~100s proxy timeout — needed
# for Cloud Run cold starts that can take >100s.
resource "cloudflare_record" "custom_domain" {
  count   = var.custom_domain != "" && var.zone_id != null ? 1 : 0
  zone_id = var.zone_id
  name    = trimsuffix(var.custom_domain, ".${data.cloudflare_zone.this[0].name}")
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = false
}

data "cloudflare_zone" "this" {
  count   = var.custom_domain != "" && var.zone_id != null ? 1 : 0
  zone_id = var.zone_id
}

# Output the Worker URL
output "worker_url" {
  value = "https://${cloudflare_worker_script.proxy.name}.${var.cloudflare_account_id}.workers.dev"
}

output "custom_domain" {
  value = var.custom_domain != "" ? "https://${var.custom_domain}" : null
}
