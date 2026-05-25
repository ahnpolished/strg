output "network_volume_id" {
  description = "Persistent RunPod network volume ID for model weights and checkpoints."
  value       = runpod_network_volume.model_weights.id
}

output "network_volume_mount_path" {
  description = "Path where the persistent model volume is mounted in trainer pods."
  value       = local.model_volume_path
}

output "pod_ids" {
  description = "RunPod trainer pod IDs. Empty when pod_count is 0."
  value       = runpod_pod.trainer[*].id
}

output "pod_names" {
  description = "RunPod trainer pod names."
  value       = runpod_pod.trainer[*].name
}

output "pod_public_ips" {
  description = "Public IPs for trainer pods, when assigned by RunPod."
  value       = runpod_pod.trainer[*].public_ip
}

output "pod_cost_per_hour" {
  description = "Hourly cost for each running pod in RunPod credits, as reported by RunPod."
  value       = runpod_pod.trainer[*].cost_per_hr
}
