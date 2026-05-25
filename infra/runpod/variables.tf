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
  description = "Primary RunPod GPU type. RTX 4090 and RTX 3090 both provide 24GB VRAM. Ignored when gpu_type_ids is non-empty."
  type        = string
  default     = "NVIDIA GeForce RTX 4090"
}

variable "gpu_type_ids" {
  description = "Ordered GPU fallback list for availability. Use RTX 4090/3090 for the low-budget 24GB VRAM research phase."
  type        = list(string)
  default = [
    "NVIDIA GeForce RTX 4090",
    "NVIDIA GeForce RTX 3090",
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
  description = "Data centers pods may launch in. Must include the volume's data_center_id for volume attachment. Defaults to data_center_id when empty."
  type        = list(string)
  default     = []
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
  description = "Mount path for the persistent RunPod network volume inside trainer pods."
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
  description = "Minimum vCPUs per GPU."
  type        = number
  default     = 8
}

variable "min_ram_per_gpu" {
  description = "Minimum RAM in GB per GPU."
  type        = number
  default     = 24
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
  default     = true
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
