terraform {
  required_version = ">= 1.5.0"

  required_providers {
    runpod = {
      source  = "decentralized-infrastructure/runpod"
      version = "~> 1.0"
    }
  }
}

provider "runpod" {
  # Prefer RUNPOD_API_KEY in the environment. Set var.runpod_api_key only for
  # local experiments and never commit secrets in .tfvars files.
  api_key = var.runpod_api_key
}
