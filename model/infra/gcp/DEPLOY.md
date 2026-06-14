# GCP GPU Serving — Deployment Sequence

Complete step-by-step guide to deploy the strg-model GPU inference
service on GCP Cloud Run with an L4 GPU. Estimated total time: ~45 min
(mostly waiting for the 14 GB model upload).

## 0. Prerequisites

```bash
# Verify these are already set up
gcloud config set project ahnpolished
gcloud auth application-default login           # Terraform auth
gcloud auth application-default set-quota-project ahnpolished  # required for billingbudgets API
gh auth status                                   # GitHub CLI (for secrets automation)
```

## 1. Configure `terraform.tfvars`

```bash
cd model/infra/gcp
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — only **one value** needs changing from defaults:

```hcl
# terraform.tfvars — all defaults correct for ahnpolished except:
github_repo = "ahnpolished/strg"   # ← your actual GitHub repo
```

All other defaults are correct:

| Variable           | Value                | Notes                                |
|--------------------|----------------------|--------------------------------------|
| `project`          | `"ahnpolished"`      | matches gcloud config                |
| `region`           | `"us-central1"`      | L4 quota region                      |
| `load_in_4bit`     | `true`               | bitsandbytes NF4, faster cold starts |
| `budget_amount`    | `10`                 | $10/month alerts only                |
| `budget_email`     | `"stahn1995@gmail.com"` |                                   |
| `finetune_instance_count` | `0`           | GCE fallback disabled until needed   |

## 2. Stage 1 — Safe resources (no GPU quota)

These resources never hit the GPU quota — safe to apply now:

```bash
terraform init
terraform plan
terraform apply
```

**Creates:** enabled APIs, GCS weights bucket, Artifact Registry Docker repo,
$10 billing budget + email alerts, WIF (Workload Identity Federation) for
GitHub Actions.

## 3. Push WIF secrets to GitHub Actions

```bash
bash scripts/gh-set-secrets.sh
```

Reads Terraform outputs and sets in `ahnpolished/strg`:

| Name                | Type     | Value                              |
|---------------------|----------|------------------------------------|
| `GCP_WIF_PROVIDER`  | secret   | WIF provider resource name         |
| `GCP_WIF_SA`        | secret   | `github-actions@ahnpolished...`    |
| `GCP_PROJECT`       | variable | `ahnpolished`                      |

Verify:

```bash
gh secret list --repo ahnpolished/strg
gh variable list --repo ahnpolished/strg
```

## 4. Upload model weights to GCS

One-time upload: Qwen2-VL-7B-Instruct (~14 GB from HuggingFace) +
LoRA adapter (~20 MB from W&B).

```bash
export GCS_BUCKET="$(terraform output -raw weights_bucket_name)"
bash scripts/upload-weights.sh
```

Wait time: ~15–30 minutes depending on network speed.

After completion, the bucket contains:

```
gs://<bucket>/weights/
  Qwen2-VL-7B-Instruct/   ← base model (~14 GB)
  lora/                    ← fine-tuned adapter (~20 MB)
```

## 5. Build and push Docker image

### Option A — Local (initial test)

```bash
# Authenticate Docker to Artifact Registry
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

# Build and push from repo root
cd ../../..   # back to repo root
docker build \
  -f model/Dockerfile \
  -t us-central1-docker.pkg.dev/ahnpolished/strg-serve/serve:latest \
  -t us-central1-docker.pkg.dev/ahnpolished/strg-serve/serve:"$(git rev-parse HEAD)" \
  ./model

docker push us-central1-docker.pkg.dev/ahnpolished/strg-serve/serve:latest
docker push us-central1-docker.pkg.dev/ahnpolished/strg-serve/serve:"$(git rev-parse HEAD)"
```

### Option B — Via GitHub Actions (full CI/CD)

Commit and push — the workflow at `.github/workflows/gcp-deploy.yml`
handles the rest:

```bash
git add -A
git commit -m "feat: GCP GPU serving infra"
git push origin main
```

The GHA pipeline runs: **checkout → WIF auth → Docker build (cached)
→ push to Artifact Registry → deploy to Cloud Run → smoke test.**

Watch it:

```bash
gh run watch
```

## 6. Stage 2 — Cloud Run GPU service

**This step tests the Cloud Run L4 GPU quota.** If quota is 0, the apply
fails — skip to the GCE fallback section at the bottom.

### If you built via Option A (local):

```bash
cd model/infra/gcp
terraform apply
```

Creates the GPU Cloud Run service (`min-instances=0`, `max-instances=1`,
`concurrency=1`) and the GCE fine-tune VM module (disabled, `count=0`).

### If you built via Option B (GitHub Actions):

The GHA deploy step already created/updated the Cloud Run revision.
Run `terraform apply` once to reconcile state (no changes expected):

```bash
cd model/infra/gcp
terraform apply
```

## 7. Smoke test

```bash
SERVE_URL="$(terraform output -raw serve_url)"
echo "Serving at: $SERVE_URL"
```

### 7a. Health check

The first request triggers a **cold start** — the container downloads
~14 GB from GCS then loads the model into GPU memory. Expect ~2–3 minutes.

```bash
# Immediate — should return 200 with status "warmup" or error if not ready yet
curl -s "$SERVE_URL/health" | python3 -m json.tool
# {"status":"warmup","model":"Qwen2-VL-7B-Instruct","lora_checkpoint":null,"device":"loading"}

# Wait for model to finish loading
sleep 90

# Should now show "ready"
curl -s "$SERVE_URL/health" | python3 -m json.tool
# {"status":"ready","model":"Qwen2-VL-7B-Instruct","lora_checkpoint":"/tmp/model/lora","device":"cuda:0"}
```

### 7b. Real prediction

```bash
curl -s -X POST \
  -F "image=@data/test/001.jpg" \
  "$SERVE_URL/predict" | python3 -m json.tool
```

Expected response shape:

```json
{
  "entries": [
    {
      "exercise": "Bench Press",
      "reps": 10,
      "sets": 3,
      "weight_lbs": 135.0,
      "date": "2025-06-01",
      "notes": null
    }
  ],
  "latency_s": 2.34,
  "entry_count": 1
}
```

### 7c. Feedback endpoint

```bash
curl -s -X POST \
  -F "image=@data/test/001.jpg" \
  -F 'entries=[{"exercise":"Squat","reps":5,"sets":3,"weight_lbs":225.0}]' \
  "$SERVE_URL/feedback" | python3 -m json.tool
# {"status":"ok","feedback_id":"feedback_20250614-120000","entries_saved":1}
```

## 8. Verify billing

After the smoke test, open the GCP Console → Billing:

- Confirm only a few cents of GPU time were consumed
- Confirm the budget is active at `$5 / $8 / $10` thresholds
- With `min-instances=0`, you pay **only for the seconds requests are
  being processed** — idle time costs $0

## 9. Full GHA cycle test

Make a trivial change to verify the CI/CD pipeline end-to-end:

```bash
# Add a comment somewhere in serve.py, then:
git add -A && git commit -m "test: verify GHA deploy pipeline"
git push origin main
gh run watch
```

On subsequent pushes where only source code changes (not dependencies),
the Docker build **reuses the `uv sync` cache layer** — build time drops
from ~10 min to ~2 min.

---

## GCE fallback (if Cloud Run GPU quota is denied)

If `terraform apply` at step 6 fails with:

```
Error: Quota 'NVIDIA_L4_GPUS' exceeded. limit: 0.0
```

### 9a. Enable the GCE spot VM

```bash
# In terraform.tfvars, flip:
finetune_instance_count = 1

terraform apply
```

Creates a `g2-standard-4` spot VM with 1× NVIDIA L4 GPU (~$0.25/hr).

### 9b. Get the VM IP and SSH in

```bash
INSTANCE="$(terraform output -raw finetune_instance_names | tr -d '[]"')"
ZONE="us-central1-a"
gcloud compute ssh "$INSTANCE" --zone="$ZONE"
```

### 9c. On the VM — start serving

```bash
# Clone the repo and install deps
git clone git@github.com:ahnpolished/strg.git
cd strg/model
uv sync --package models-server

# Download weights from GCS (same bucket created in step 2)
GCS_BUCKET="$(curl -sH 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/attributes/gcs-bucket')"
mkdir -p /tmp/model
gsutil -m cp -r "gs://${GCS_BUCKET}/weights/Qwen2-VL-7B-Instruct/" /tmp/model/
gsutil -m cp -r "gs://${GCS_BUCKET}/weights/lora/" /tmp/model/

# Start the server
export STRG_QWEN_MODEL_PATH=/tmp/model/Qwen2-VL-7B-Instruct
export STRG_QWEN_LORA_CHECKPOINT=/tmp/model/lora
export STRG_QWEN_LOAD_IN_4BIT=true
uv run python -m models_server.serve --host 0.0.0.0 --port 8080
```

### 9d. Tear down when done

```bash
# Back on your local machine
cd model/infra/gcp
terraform apply -var='finetune_instance_count=0'
```

Same apply → run → destroy discipline as RunPod.

---

## Architecture diagram

```
GitHub (ahnpolished/strg)
  │
  │  git push to main
  ▼
GitHub Actions (.github/workflows/gcp-deploy.yml)
  │
  │  WIF auth → docker build → push → deploy
  ▼
Artifact Registry (us-central1-docker.pkg.dev/ahnpolished/strg-serve)
  │
  │  Cloud Run pulls image on revision deploy
  ▼
Cloud Run GPU (strg-serve)
  │  min-instances=0, max=1, concurrency=1
  │  L4 GPU, 24 GiB RAM, 30 GiB ephemeral storage
  │
  ├─ Cold start: gsutil cp weights from GCS (~2 min)
  ├─ Load Qwen2-VL-7B + LoRA into GPU (4-bit NF4, ~5 GiB VRAM)
  └─ Serve: FastAPI / uvicorn on :8080
       │
       ├─ POST /predict   → workout extraction
       ├─ POST /feedback  → corrected data collection
       └─ GET  /health    → readiness probe

GCS (ahnpolished-strg-weights)
  ├─ weights/Qwen2-VL-7B-Instruct/  (~14 GB base model)
  └─ weights/lora/                   (~20 MB LoRA adapter)

Billing Budget ($10/month)
  ├─ 50% ($5)  → email alert
  ├─ 80% ($8)  → email alert
  └─ 100% ($10) → email alert

WIF (Workload Identity Federation)
  └─ github-actions SA → artifactregistry.writer + run.admin
     (scoped to repo ahnpolished/strg only)

GCE Fallback (finetune.tf, count=0)
  └─ g2-standard-4 spot VM (1× L4), apply → run → destroy
```

## Quick reference

| Command | Purpose |
|---------|---------|
| `terraform output -raw serve_url` | Get the Cloud Run HTTPS endpoint |
| `terraform output -raw weights_bucket_name` | Get the GCS bucket name |
| `terraform output -raw docker_repo_url` | Get the Artifact Registry Docker URL |
| `bash scripts/upload-weights.sh` | One-time weights upload to GCS |
| `bash scripts/gh-set-secrets.sh` | Push WIF credentials to GitHub |
| `gh run watch` | Watch the GHA deploy pipeline |
| `terraform apply -var='finetune_instance_count=0'` | Destroy GCE fallback VM |
