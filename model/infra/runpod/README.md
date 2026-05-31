# RunPod Terraform infra

Terraform configuration for GPU training/evaluation pods on RunPod.
It targets a low-cost research GPU set by default: 48 GB GPUs first (A40 / RTX A6000), then cheaper 24 GB fallbacks (RTX 3090 / RTX A5000 / RTX 4090), with RTX 6000 Ada last. Premium 80 GB GPUs such as A100/H100 are intentionally excluded from the default.

## What this creates

- `runpod_network_volume.model_weights`: persistent network volume for model weights, datasets, and checkpoints.
- `runpod_pod.trainer`: zero or more GPU pods attached to that volume.

Cost safety defaults:

- `pod_count = 0`, so `terraform apply` creates only the persistent volume unless you intentionally request running pods.
- The example tfvars defaults trainer pods to `interruptible = false` because on-demand capacity is more likely to schedule than interruptible/spot capacity.
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
- `gpu_type_ids`: ordered low-cost GPU fallback list using RunPod API enum names, not the shortened console display names. Premium 80 GB GPUs are excluded by default; add A100/H100 manually only when needed.
- `image_name`: training image. Defaults to a RunPod PyTorch CUDA image.
- `attach_network_volume`: set `false` for highest scheduling success across data centers; set `true` when persistent attached checkpoint storage is required.
- `volume_mount_path`: only applies when `attach_network_volume = true`. With no network volume attached, pods use `/workspace` like the provider examples.
- `interruptible`: set `false` for on-demand capacity; set `true` only when lower cost is worth spot-capacity failures/interruptions.
- `data_center_id`: data center for the network volume.
- `data_center_ids`: pod data center constraints. When `attach_network_volume = false`, leave this as `[]` to let RunPod choose any data center. When `attach_network_volume = true`, network volumes must be in the same data center as attached pods, so include `data_center_id` here.
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

## Automated test loop

`scripts/test-loop.sh` runs a full provision → SSH test → teardown cycle and repeats it N times. Useful for regression testing code changes against a clean pod on each iteration.

**First-time setup: SSH key injection**

The loop injects your SSH public key into the pod via the `PUBLIC_KEY` env var (RunPod's official images write it to `/root/.ssh/authorized_keys` on startup). Export it before running:

```bash
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_rsa.pub)"
```

Or add it permanently to your shell profile. Do not commit this to `terraform.tfvars`.

**One-shot run** (provision, test, teardown once):

```bash
cd infra/runpod
scripts/test-loop.sh
```

**Run N iterations** (fresh pod each time):

```bash
scripts/test-loop.sh --iterations 3
```

**Run forever** (until Ctrl-C or a teardown failure):

```bash
scripts/test-loop.sh --iterations 0
```

**Customize the test commands:**

Edit `scripts/pod-tests.sh` — this is the script sent to the pod via SSH on each iteration.

**Other options:**

```
--ssh-key PATH       Private key (default: ~/.ssh/id_rsa)
--ssh-user USER      Pod user (default: root)
--ssh-port PORT      SSH port (default: 22)
--test-script PATH   Script to run on pod (default: scripts/pod-tests.sh)
--remote-dir PATH    Remote working dir (default: /workspace/strg)
--no-sync            Skip rsync (if code is baked into the pod image)
--ip-timeout SECS    Max wait for IP (default: 180s)
--ssh-timeout SECS   Max wait for SSH readiness (default: 300s)
--dry-run            Print steps without provisioning
```

**Loop safety:** if teardown fails on any iteration, the loop stops immediately (exit 2) rather than piling up orphaned pods. Check the RunPod console if this happens.

**SSH connectivity note:** with `support_public_ip = true` (the default in example tfvars), RunPod assigns a real public IP and port 22 is directly reachable. If SSH never becomes available after 300s, first check that `support_public_ip = true` and port `22/tcp` is in your `ports` list.

## Suggested training workflow

1. Keep `pod_count = 0` while preparing code and datasets.
2. Set `pod_count = 1`, then `terraform plan` and `terraform apply` when ready to train.
3. Clone/sync the repo into the pod under `/workspace`.
4. Use the fast RunPod install script instead of `uv sync --all-packages`:

```bash
./scripts/runpod_install_fast.sh
```

The RunPod PyTorch image is `py3.11`, so the repo pins `.python-version` to `3.11` and the package metadata allows `>=3.11,<3.13`. Avoid Python 3.14: many ML/image wheels are not available there yet, causing slow source builds or failures such as Pillow missing zlib headers.

For evaluation-only work, install even less:

```bash
./scripts/runpod_install_fast.sh evaluation
```

The script creates a uv venv with system site packages so it can reuse the PyTorch/CUDA stack already present in the RunPod PyTorch image, skips reinstalling `torch` when available, and avoids local/iOS dependencies unless requested.

5. Use the mounted model directory from `network_volume_mount_path` for downloaded base weights and checkpoints.
6. Run evaluation/fine-tuning jobs.
7. Immediately run `./scripts/teardown.sh` or apply `pod_count = 0` when the run is finished.

## Notes

- Network volumes and attached pods must be in the same RunPod data center.
- If pod creation fails with “There are no longer any instances available” or “This machine does not have the resources,” the usual constraints are data center pinning, network volume attachment, interruptible/spot capacity, oversized pod/container disks, GPU-specific CPU/RAM constraints, and global networking. For the highest chance of scheduling, use `attach_network_volume = false`, `data_center_ids = []`, `interruptible = false`, `global_networking = false`, small `pod_volume_size_gb` / `container_disk_in_gb`, null `min_vcpu_per_gpu` / `min_ram_per_gpu`, and the broad low-cost `gpu_type_ids` fallback list.
- Community cloud GPU availability varies. Keep multiple low-cost 48 GB and 24 GB GPUs in `gpu_type_ids` to improve scheduling chances. Avoid putting A100/H100 in the default list unless the run explicitly needs 80 GB VRAM.
- `terraform.tfvars`, plans, state, and provider cache files are ignored in this directory.
