# strg-model

Monorepo for training and evaluating ML models that extract structured workout data from handwritten journal photos.

## Structure

```
strg/
├── packages/common/     # Shared Pydantic schema (WorkoutEntry, WorkoutPage)
├── models/server/       # Server-side model experiments (Qwen2-VL, InternVL2, Florence-2, Donut)
├── models/local/        # Local/on-device model experiments (moondream2, SmolVLM, MiniCPM-V, Phi-3.5)
├── evaluation/          # Evaluation harness: CER + field-level accuracy, W&B logging
└── data/
    ├── test/            # 22-photo evaluation set (jpg + json ground truth per photo)
    └── train/           # Training set (90/10 split, versioned as W&B artifacts)
```

## Dev setup

```bash
uv sync --all-packages
pre-commit install
```

## Running evaluation

```bash
uv run python -m evaluation.run --model <name> --predictions data/predictions/<path> --ground-truth data/test
```

## Key decisions

- Output schema: `WorkoutPage` (list of `WorkoutEntry`) defined in `packages/common`
- Accuracy targets: field-level exact match >= 90% AND CER <= 10%
- Server model fine-tuning: QLoRA via HuggingFace PEFT
- Local model export: CoreML for iOS
- Experiment tracking: W&B project `strg-model`

## Autoresearch loop history (W&B tracked)

| Date     | Run ID               | Model     | CER   | Field Acc | Change vs prev        |
|----------|----------------------|-----------|-------|-----------|-----------------------|
| 20260528 | matrix-070837        | qwen2-vl  | 0.116 | 0.804     | baseline (best known) |
| 20260528 | matrix-071913        | qwen2-vl  | 0.177 | 0.766     | regression (GPU diff) |
| 20260530 | matrix-085608        | qwen2-vl  | 0.172 | 0.776     | +prompt rules (DO NOT aggregate, seq-of-reps) |
| 20260530 | matrix-090904        | internvl2 | 0.210 | 0.508     | +57 extra entries (over-predicts complex layouts) |
| 20260530 | finetune-eval-4wtagw2i | qwen2-vl (fine-tuned) | **0.051** | **0.882** | 3 epochs QLoRA, 100 train + 20 val images, A40 |

**Fine-tuning result**: CER 0.172→0.051 (−70%), ACC 0.776→0.882 (+13.6%). CER target (≤0.10) achieved. ACC target (≥0.90) missed by 1.8%.

**Val set performance**: CER 0.066, ACC 0.989 — model excels on synthetic val data.

**Key bugs fixed during fine-tuning**:
- `eval_steps=50→100` (eval too slow on val set, generate() takes ~20min per run)
- Label masking was wrong: `prompt_ids` computed WITHOUT image tokens, causing mid-prompt label leakage
- Evaluate function rebuilt to use proper inference pipeline (`add_generation_prompt=True`)
- Disabled PyTorch torch.compile workers (32+ processes eating CPU)

**Two best models confirmed**: qwen2-vl (#1) and internvl2 (#2). Debugging phase COMPLETE.

**Key failure analysis**:
- qwen2-vl: under-predicts on table layouts (photo-019: 5 pred vs 18 GT). Total: 141/156 entries.
- internvl2: over-predicts on set-countdown + grouped layouts (photos 011,014,021). Total: 202/156 entries (+57 extra!).
- internvl2 handles landscape-column layout well (photo-019: 17/18) — complementary to qwen2-vl.

**Next action**: Fine-tune qwen2-vl. Infrastructure fixed (HF_HOME on container disk, 20GB volume). Waiting for SECURE capacity (H2 transient crunch since 09:37). Budget spent: ~$0.40 of $10.

**Fine-tuning deliverable**: A measured delta logged to W&B (run phase=finetune-eval) compared to baseline (matrix-085608). Crossing CER≤0.10/ACC≥0.90 in one pass is aspirational. The loop iteration — train, measure, document — is the required output. After fine-tuning completes, confirm the finetune-eval W&B run has real CER/ACC values before declaring success.

## Autoresearch loop (Karpathy-style)

Goal: systematically close the gap to CER ≤ 0.10 AND field accuracy ≥ 0.90, tracked by W&B.

### Principle

Never fix randomly. Measure → identify the single biggest delta → make the minimal targeted change → measure again. W&B is the scoreboard.

### Loop steps

1. **Check W&B** for the latest run metrics. Compare CER and per-field accuracy to baseline.
2. **Find worst photos**: Run local eval and compare `pred_entries vs gt_entries` per photo.
   ```bash
   WANDB_MODE=disabled uv run python -m evaluation.run \
     --model qwen2-vl \
     --predictions infra/runpod/logs/predictions/<latest-run>/qwen2-vl \
     --ground-truth data/test --phase offline-check
   ```
3. **Identify failure mode** by inspecting the specific photo. Categories:
   - `table-layout`: model outputs one summary row instead of N per-set rows
   - `date-error`: wrong date format or digit (check photo vs prediction)
   - `reps-error`: ambiguous notation causes wrong reps count
   - `extra-entries`: model splits one entry into multiple
   - `empty`: model returns no entries at all
4. **Make one targeted change**. In order of ROI:
   - **prompt rule**: add a concrete example for the specific failure pattern
   - **post-processing**: add normalization in `qwen2_vl.py:_normalize_entries`
   - **token budget**: increase `STRG_QWEN_MAX_VISUAL_TOKENS` for detail-heavy pages
   - **fine-tuning**: QLoRA on `data/train` when prompt/post-processing has plateau
5. **Run on RunPod** with `--models qwen2-vl --max-parallel 1`. Cost ~$0.35/run.
6. **Measure delta**: compare new W&B run vs previous. Commit only if CER improves or does not regress.
7. **Repeat** until both thresholds pass.

### Budget tracking ($10 total)

- Debug/eval runs: ~$0.44/pod-hour (SECURE on-demand — COMMUNITY was unavailable 2026-05-30)
- Fine-tuning run: ~$1.32 for ~3hr QLoRA on A40
- Spent so far (2026-05-30): ~$0.23 ($0.08 qwen2-vl + $0.15 internvl2)
- Remaining: ~$9.77
- Watch: `terraform destroy` must run after every session — one orphaned overnight pod = whole budget

### Running the matrix

```bash
# Source env vars first — see infra/runpod/README.md
source .envrc  # or manually: export RUNPOD_API_KEY=... TF_VAR_ssh_public_key=...

# Debug single model (cheapest, ~$0.35):
bash infra/runpod/scripts/model-matrix-loop.sh \
  --models qwen2-vl \
  --max-parallel 1 \
  --cloud-type COMMUNITY

# Both top candidates sequentially:
bash infra/runpod/scripts/model-matrix-loop.sh \
  --models qwen2-vl,internvl2 \
  --max-parallel 1 \
  --cloud-type COMMUNITY
```

### Known failure patterns (do not re-investigate)

- **SECURE cloud + 3 pods = all fail**: RunPod SECURE has low capacity for multi-pod batches.
- **COMMUNITY cloud + 1 pod = capacity error (2026-05-30 09:00)**: All COMMUNITY GPU types showed "no instances available". SECURE + 1 pod at $0.44/hr succeeded. Use `--cloud-type SECURE --max-cost-per-hour 2.00` when COMMUNITY is unavailable.
- **SECURE cloud transient crunch (2026-05-30 09:37+)**: After internvl2 teardown, SECURE capacity became unavailable for ~1hr — 20GB and 30GB pods both failed identically. This is H2 (transient crunch), not H1 (size filter). Stop retrying with short delays; wait 15-20 min.
- **Fine-tuning disk quota (20GB pod volume)**: Model weights (~14GB) + uv cache (~6GB) fills the 20GB /workspace. Fix: set `HF_HOME=/root/.hf-cache` in pod-finetune.sh to use the separate 20GB container disk instead. Do NOT increase pod_volume_size_gb to 50+ (hurts scheduling).
- **Network volume 404**: After credit renewal, the old volume `atf6dcg14t` was deleted. Fixed by making `runpod_network_volume` conditional (`count = var.attach_network_volume ? 1 : 0`) and removing from state with `terraform state rm runpod_network_volume.model_weights`.
- **photo 019 table layout**: qwen2-vl outputs 5 entries vs 18 GT. Model sees summary rows, not individual set rows. Prompt rule for "column of rep values" is partially implemented but incomplete.
- **photo 011 set countdown**: model treats set-number countdown (5,4,3,2,1) as separate rows; GT uses per-set reps rows. Partially a data-convention mismatch.

### Fine-tuning path

Scripts:
- `models/server/src/models_server/finetune_qwen2_vl.py` — QLoRA for qwen2-vl (best model)
- `models/server/src/models_server/finetune_internvl2.py` — QLoRA for internvl2

Training data: `data/train/` (100 synthetic images) + `data/val/` (20 images).
Generated by: `uv run python data/generate_train_data.py --count 100 --seed 42`
The compact layout (2/3 of images) specifically targets the photo-019 failure pattern.

**Launch fine-tuning on RunPod**:
```bash
export TF_VAR_env='{"STRG_FINETUNE_MODEL":"qwen2-vl","STRG_EPOCHS":"3"}'
bash infra/runpod/scripts/model-matrix-loop.sh \
  --models qwen2-vl \
  --max-parallel 1 \
  --cloud-type SECURE \
  --max-cost-per-hour 2.00 \
  --batch-timeout 14400 \
  --test-script infra/runpod/scripts/pod-finetune.sh
```

Cost: ~$0.44 × 2-3hrs = ~$0.88-$1.32 per fine-tuning run. Budget: $5 → ~3-4 runs.

Do NOT fine-tune on images in `data/test/` — that's the eval set.

## Parallel agent usage

- **Safe to parallelize**: read-only tasks (error analysis per model, code review, metric inspection)
- **Never parallelize**: terraform operations — shared `terraform.tfstate` will race and corrupt

## Handoff protocol (for usage-limit continuations)

When Claude hits a usage limit, open a new tmux pane and continue:
```bash
tmux new-session -d -s strg-finetune
tmux send-keys -t strg-finetune "cd /Users/taeahn/devs/personal/2026/strg && claude" Enter
```

### Current state (as of 2026-05-30 ~18:00)

**What's done:**
- ✅ **Fine-tuning complete!** qwen2-vl QLoRA 3 epochs on 100 synthetic training images
- Test set: CER **0.051** (target ≤0.10 ✅), Field Acc **0.882** (target ≥0.90 ❌ miss by 1.8%)
- Val set: CER **0.066** (✅), Field Acc **0.989** (✅ — synthetic val data)
- W&B logged: training run (h5gpxcle) + finetune-eval (4wtagw2i)
- Improvement vs baseline: CER 0.172→0.051 (−70%), ACC 0.776→0.882 (+13.6%)

**All bugs found and fixed:**
1. `eval_steps=50` too high (never fired). Fixed to 100 (avoid slow val generation)
2. Eval leaked ground-truth answer to `generate()`. Fixed: proper prompt construction
3. Label masking broke: `prompt_ids` computed WITHOUT image tokens → mask ended mid-prompt
4. Final checkpoint never saved. Fixed: fallback save at end of training
5. Training images not synced (gitignore + rsync exclude). Fixed both.
6. PyTorch torch.compile workers (32+ processes) eating CPU. Disabled.
7. Rsync command broken by bash comments in multiline continuation.

**What to do next for ACC improvement (88.2%→90%+):**
1. **More training data** (200+ images instead of 100)
2. **More epochs** (5-10 instead of 3)
3. **Better synthetic data** — include more table-layout examples (current weakness)
4. Focus on improving `date` (84.1%) and `reps` (84.1%) fields — model struggles with date formats and rep countdown patterns

**Key files:**
- `infra/runpod/scripts/pod-finetune.sh` — runs on pod (install + generate data + fine-tune + eval)
- `models/server/src/models_server/finetune_qwen2_vl.py` — QLoRA training script (all bugs fixed)
- `models/server/src/models_server/serve.py` — FastAPI serving API for mobile app backend
- `models/server/docker/Dockerfile` — Docker image for deployment
- `models/server/src/models_server/qwen2_vl.py` — inference runner with `STRG_QWEN_LORA_CHECKPOINT` support
- `data/train/` — 100 synthetic training images (compact + tabular layouts)
- `data/val/` — 20 synthetic val images

## Serving API (for mobile app backend)

### Quick start (local)
```bash
uv sync --package models-server
STRG_QWEN_LORA_CHECKPOINT=/path/to/lora uv run python -m models_server.serve
```
Then `curl -X POST -F "image=@photo.jpg" http://localhost:8000/predict`.

### Endpoints
- `POST /predict` — Upload image (multipart), returns `{"entries": [...], "latency_s": 3.2, "entry_count": 12}`
- `GET /health` — Returns model status and loaded LoRA checkpoint path

### Deployment options (by cost)

| Option | Cost/hr | Setup Time | Notes |
|--------|---------|------------|-------|
| **RunPod Serverless** | ~$0.50-1.50 | Minutes | Best for production: auto-scaling, no cold-start if kept warm |
| **Self-hosted GPU VPS** (Vast.ai, Lambda) | ~$0.50-1.00 | Hours | Cheaper, needs Docker + Nginx |
| **AWS SageMaker** | ~$1.50+ | Days | Most robust, highest overhead |

### Re-running fine-tuning for checkpoint
Since the checkpoint was lost with the pod, re-run with:
```bash
set -a; source .env; set +a
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
export STRG_FINETUNE_MODEL=qwen2-vl STRG_EPOCHS=3
export STRG_INTERRUPTIBLE=true  # or false for on-demand
bash infra/runpod/scripts/model-matrix-loop.sh \
  --models qwen2-vl --max-parallel 1 --cloud-type SECURE \
  --max-cost-per-hour 2.00 --batch-timeout 18000 \
  --test-script infra/runpod/scripts/pod-finetune.sh

# After training completes, fetch checkpoint:
# The predict/ directory and eval results are saved locally.
# For the LoRA checkpoint itself, either:
# 1. SSH into the pod and copy checkpoints/qwen2-vl/best/ before teardown, or
# 2. Modify finetune_qwen2_vl.py to upload to W&B artifact properly (fix disk space)
```
