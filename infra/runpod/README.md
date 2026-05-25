# RunPod Terraform infra

Terraform configuration for low-budget GPU training/evaluation pods on RunPod.
It targets 24 GB VRAM GPUs (RTX 4090/3090 by default) for STRG model experiments: local VLM evaluation, QLoRA fine-tuning, and checkpoint/model-weight storage.

## What this creates

- `runpod_network_volume.model_weights`: persistent network volume for model weights, datasets, and checkpoints.
- `runpod_pod.trainer`: zero or more GPU pods attached to that volume.

Cost safety defaults:

- `pod_count = 0`, so `terraform apply` creates only the persistent volume unless you intentionally request running pods.
- Trainer pods default to `interruptible = true` for lower-cost spot capacity.
- `max_pod_count_guardrail = 2` prevents accidentally applying a large fleet.
- The network volume has `prevent_destroy = true` because checkpoints are expensive to recreate.
- `scripts/teardown.sh` destroys trainer pods without deleting the persistent volume.

## Prerequisites

1. Terraform >= 1.5.
2. A RunPod API key from the RunPod console.
3. Export the API key in your shell:

```bash
export RUNPOD_API_KEY="<your-runpod-api-key>"
```

Do not commit API keys or local `.tfvars` files.

## Configure

Copy the example variables file and edit it for the target RunPod data center/GPU availability:

```bash
cd infra/runpod
cp terraform.tfvars.example terraform.tfvars
```

Important variables:

- `pod_count`: number of trainer pods. Keep at `0` when idle; set to `1` only for active training/evaluation.
- `gpu_type_ids`: ordered GPU fallback list. Defaults to RTX 4090 then RTX 3090.
- `image_name`: training image. Defaults to a RunPod PyTorch CUDA image.
- `data_center_id`: data center for the network volume.
- `data_center_ids`: pod data center constraints. Network volumes must be in the same data center as attached pods, so include `data_center_id` here.
- `network_volume_size_gb`: persistent model/checkpoint storage size.
- `ports`: pod ports, defaulting to SSH, Jupyter, and TensorBoard.

## Initialize

```bash
terraform init
```

## Plan

Plan the default low-cost state (persistent volume, no running GPU pod):

```bash
terraform plan -out=tfplan
```

Plan a single active trainer pod:

```bash
terraform plan -var='pod_count=1' -out=tfplan
```

## Apply

```bash
terraform apply tfplan
```

After apply, inspect outputs for pod IDs, public IPs, mount paths, and hourly cost:

```bash
terraform output
```

## Teardown / avoid idle billing

Destroy running trainer pods while keeping the persistent model volume:

```bash
./scripts/teardown.sh
```

Or equivalently:

```bash
terraform destroy -target=runpod_pod.trainer
```

To keep the volume but scale pods to zero through normal Terraform state reconciliation:

```bash
terraform apply -var='pod_count=0'
```

Only delete the network volume after backing up any checkpoints or model weights:

```bash
./scripts/teardown.sh --all
```

The `--all` mode temporarily removes the volume `prevent_destroy` lifecycle guard, prompts for confirmation, and restores the file afterward.

## Suggested training workflow

1. Keep `pod_count = 0` while preparing code and datasets.
2. Set `pod_count = 1`, then `terraform plan` and `terraform apply` when ready to train.
3. Use the mounted model directory from `network_volume_mount_path` for downloaded base weights and checkpoints.
4. Run evaluation/fine-tuning jobs.
5. Immediately run `./scripts/teardown.sh` or apply `pod_count = 0` when the run is finished.

## Notes

- Network volumes and attached pods must be in the same RunPod data center.
- Community cloud GPU availability varies. Keep both RTX 4090 and RTX 3090 in `gpu_type_ids` to improve scheduling chances.
- `terraform.tfvars`, plans, state, and provider cache files are ignored in this directory.
