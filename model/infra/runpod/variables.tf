variable "runpod_api_key" {
  description = "RunPod API key. Prefer setting RUNPOD_API_KEY in the environment instead of this variable."
  type        = string
  sensitive   = true
  default     = null
}

variable "name_prefix" {
  description = "Prefix used for RunPod resource names."
  type        = string
  default     = "strg"

  validation {
    condition     = length(trimspace(var.name_prefix)) > 0
    error_message = "name_prefix cannot be empty."
  }
}

variable "pod_count" {
  description = "Number of GPU trainer pods to run. Defaults to 0 to avoid accidental idle GPU billing; set to 1+ only when actively training."
  type        = number
  default     = 0

  validation {
    condition     = var.pod_count >= 0 && floor(var.pod_count) == var.pod_count
    error_message = "pod_count must be a non-negative integer."
  }
}

variable "max_pod_count_guardrail" {
  description = "Safety guardrail for maximum pod_count in one apply. Raise intentionally if a larger training fleet is needed."
  type        = number
  default     = 2

  validation {
    condition     = var.max_pod_count_guardrail >= 1
    error_message = "max_pod_count_guardrail must be at least 1."
  }
}

variable "gpu_type_id" {
  description = "Primary RunPod GPU type using the RunPod API enum name. A40 provides 48GB VRAM and currently shows medium availability in RunPod. Ignored when gpu_type_ids is non-empty."
  type        = string
  default     = "NVIDIA A40"
}

variable "gpu_type_ids" {
  description = "Ordered low-cost research GPU fallback list using RunPod API enum names. Excludes premium 80GB GPUs by default; add A100/H100 manually only when needed."
  type        = list(string)
  default = [
    "NVIDIA A40",
    "NVIDIA RTX A6000",
    "NVIDIA GeForce RTX 3090",
    "NVIDIA RTX A5000",
    "NVIDIA GeForce RTX 4090",
    "NVIDIA RTX 6000 Ada Generation",
  ]

  validation {
    condition     = length(var.gpu_type_ids) > 0
    error_message = "gpu_type_ids must include at least one GPU type."
  }
}

variable "gpu_type_priority" {
  description = "RunPod GPU selection priority: availability or custom."
  type        = string
  default     = "availability"

  validation {
    condition     = contains(["availability", "custom"], var.gpu_type_priority)
    error_message = "gpu_type_priority must be availability or custom."
  }
}

variable "gpu_count" {
  description = "Number of GPUs per pod."
  type        = number
  default     = 1

  validation {
    condition     = var.gpu_count >= 1 && floor(var.gpu_count) == var.gpu_count
    error_message = "gpu_count must be a positive integer."
  }
}

variable "image_name" {
  description = "Docker image for training/evaluation pods."
  type        = string
  default     = "runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04"
}

variable "cloud_type" {
  description = "RunPod cloud type. COMMUNITY is usually cheaper; SECURE offers stronger isolation."
  type        = string
  default     = "COMMUNITY"
}

variable "data_center_id" {
  description = "RunPod data center for the persistent network volume. Pods must be constrained to this region when attaching the volume."
  type        = string
  default     = "US-CA-2"
}

variable "data_center_ids" {
  description = "Data centers pods may launch in. When attach_network_volume is true, this must include data_center_id and defaults to data_center_id. When attach_network_volume is false, [] leaves data center selection unconstrained."
  type        = list(string)
  default     = []
}

variable "attach_network_volume" {
  description = "Attach the persistent RunPod network volume to trainer pods. Disable temporarily to avoid data-center capacity constraints; checkpoints then live only on the pod volume unless copied elsewhere."
  type        = bool
  default     = true
}

variable "data_center_priority" {
  description = "RunPod data center selection priority: availability or custom."
  type        = string
  default     = "availability"

  validation {
    condition     = contains(["availability", "custom"], var.data_center_priority)
    error_message = "data_center_priority must be availability or custom."
  }
}

variable "network_volume_size_gb" {
  description = "Persistent network volume size for model weights, datasets, and checkpoints."
  type        = number
  default     = 100

  validation {
    condition     = var.network_volume_size_gb > 0 && var.network_volume_size_gb <= 4000
    error_message = "network_volume_size_gb must be between 1 and 4000."
  }
}

variable "volume_mount_path" {
  description = "Mount path for the persistent RunPod network volume inside trainer pods. Ignored when attach_network_volume is false; pods then use /workspace like the provider examples."
  type        = string
  default     = "/workspace/models"
}

variable "pod_volume_size_gb" {
  description = "Ephemeral pod volume size in GB, persisted across pod restarts but not intended for durable model storage."
  type        = number
  default     = 50
}

variable "container_disk_in_gb" {
  description = "Container disk size in GB. Wiped on pod restart."
  type        = number
  default     = 50
}

variable "min_vcpu_per_gpu" {
  description = "Optional minimum vCPUs per GPU. Null omits this constraint, matching the provider examples and improving scheduling chances."
  type        = number
  default     = null
}

variable "min_ram_per_gpu" {
  description = "Optional minimum RAM in GB per GPU. Null omits this constraint, matching the provider examples and improving scheduling chances."
  type        = number
  default     = null
}

variable "allowed_cuda_versions" {
  description = "Acceptable CUDA versions on the pod. Empty lets RunPod choose based on the image/GPU availability."
  type        = list(string)
  default     = []
}

variable "interruptible" {
  description = "Use interruptible/spot pods for lower cost. They can be stopped by RunPod at any time."
  type        = bool
  default     = true
}

variable "support_public_ip" {
  description = "Whether Community Cloud pods need a public IP."
  type        = bool
  default     = true
}

variable "global_networking" {
  description = "Enable RunPod global networking."
  type        = bool
  default     = false
}

variable "ports" {
  description = "Ports exposed on each pod, formatted as port/protocol."
  type        = list(string)
  default     = ["22/tcp", "8888/http", "6006/http"]
}

variable "docker_start_cmd" {
  description = "Optional Docker CMD override."
  type        = list(string)
  default     = []
}

variable "docker_entrypoint" {
  description = "Optional Docker ENTRYPOINT override."
  type        = list(string)
  default     = []
}

variable "container_registry_auth_id" {
  description = "Optional RunPod container registry credentials ID for private training images."
  type        = string
  default     = null
}

variable "wandb_project" {
  description = "Weights & Biases project injected into the pod environment."
  type        = string
  default     = "strg-model"
}

variable "env" {
  description = "Additional non-secret environment variables for trainer pods. Do not commit credentials here."
  type        = map(string)
  default     = {}
}

variable "ssh_public_key" {
  description = "SSH public key injected as PUBLIC_KEY into trainer pods. RunPod's official images write this to /root/.ssh/authorized_keys on startup. Prefer setting TF_VAR_ssh_public_key in the environment rather than committing a key here."
  type        = string
  default     = ""
  sensitive   = true
}
