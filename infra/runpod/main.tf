locals {
  name_prefix        = trimspace(var.name_prefix)
  selected_gpu_ids   = length(var.gpu_type_ids) > 0 ? var.gpu_type_ids : [var.gpu_type_id]
  selected_dc_ids    = length(var.data_center_ids) > 0 ? var.data_center_ids : (var.attach_network_volume ? [var.data_center_id] : [])
  pod_workspace_path = "/workspace"
  model_volume_path  = var.attach_network_volume ? var.volume_mount_path : local.pod_workspace_path
}

resource "runpod_network_volume" "model_weights" {
  name           = "${local.name_prefix}-models"
  size           = var.network_volume_size_gb
  data_center_id = var.data_center_id

  lifecycle {
    # Model checkpoints and downloaded weights are expensive to recreate. Remove
    # this intentionally before destroying the volume.
    prevent_destroy = true
  }
}

resource "runpod_pod" "trainer" {
  count = var.pod_count

  name       = format("%s-trainer-%02d", local.name_prefix, count.index + 1)
  image_name = var.image_name

  compute_type      = "GPU"
  cloud_type        = var.cloud_type
  gpu_count         = var.gpu_count
  gpu_type_ids      = local.selected_gpu_ids
  gpu_type_priority = var.gpu_type_priority

  data_center_ids      = local.selected_dc_ids
  data_center_priority = var.data_center_priority

  interruptible              = var.interruptible
  support_public_ip          = var.support_public_ip
  global_networking          = var.global_networking
  container_disk_in_gb       = var.container_disk_in_gb
  volume_in_gb               = var.pod_volume_size_gb
  volume_mount_path          = local.model_volume_path
  network_volume_id          = var.attach_network_volume ? runpod_network_volume.model_weights.id : null
  min_vcpu_per_gpu           = var.min_vcpu_per_gpu
  min_ram_per_gpu            = var.min_ram_per_gpu
  allowed_cuda_versions      = var.allowed_cuda_versions
  ports                      = var.ports
  docker_start_cmd           = var.docker_start_cmd
  docker_entrypoint          = var.docker_entrypoint
  container_registry_auth_id = var.container_registry_auth_id

  env = merge(
    {
      STRG_MODEL_DIR = local.model_volume_path
      WANDB_PROJECT  = var.wandb_project
    },
    var.ssh_public_key != "" ? { PUBLIC_KEY = var.ssh_public_key } : {},
    var.env,
  )

  lifecycle {
    precondition {
      condition     = contains(["COMMUNITY", "SECURE"], var.cloud_type)
      error_message = "cloud_type must be COMMUNITY or SECURE."
    }

    precondition {
      condition     = var.pod_count <= var.max_pod_count_guardrail
      error_message = "pod_count exceeds max_pod_count_guardrail. Increase the guardrail intentionally before applying."
    }

    precondition {
      condition     = !var.attach_network_volume || contains(local.selected_dc_ids, var.data_center_id)
      error_message = "When attach_network_volume is true, data_center_ids must include data_center_id so pods can attach the network volume."
    }
  }
}
