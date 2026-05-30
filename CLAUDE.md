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

## Current best results (as of 2026-05-28)

| Model      | CER   | Field Accuracy | Status          |
|------------|-------|----------------|-----------------|
| qwen2-vl   | 0.116 | 0.804          | FAIL — closest  |
| internvl2  | 0.198 | 0.570          | FAIL — second   |
| florence2  | 0.678 | 0.224          | FAIL — skip     |
| donut      | 1.000 | 0.000          | FAIL — skip     |

**Primary blocker for qwen2-vl**: photo 019 (table layout with per-set rows). Model outputs 5 summarized entries; GT has 18 per-set rows. Fix requires fine-tuning or layout-specific prompt additions.

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

- Debug/eval runs: ~$0.35/pod-hour (COMMUNITY interruptible)
- Fine-tuning run: ~$1.50-2.00 for 2-3hr QLoRA on A40 (20GB adapter, ~90 training images)
- Reserved: $5 debug (≈14 eval runs), $5 fine-tune (≈2-3 fine-tune runs)
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
- **COMMUNITY cloud + 1 pod = capacity error (2026-05-30)**: All COMMUNITY GPU types showed "no instances available" on this date. SECURE + 1 pod at $0.44/hr succeeded. Use `--cloud-type SECURE --max-cost-per-hour 2.00` when COMMUNITY is unavailable.
- **Network volume 404**: After credit renewal, the old volume `atf6dcg14t` was deleted. Fixed by making `runpod_network_volume` conditional (`count = var.attach_network_volume ? 1 : 0`) and removing from state with `terraform state rm runpod_network_volume.model_weights`.
- **photo 019 table layout**: qwen2-vl outputs 5 entries vs 18 GT. Model sees summary rows, not individual set rows. Prompt rule for "column of rep values" is partially implemented but incomplete.
- **photo 011 set countdown**: model treats set-number countdown (5,4,3,2,1) as separate rows; GT uses per-set reps rows. Partially a data-convention mismatch.

### Fine-tuning path

Fine-tuning script exists for internvl2: `models/server/src/models_server/finetune_internvl2.py`
No fine-tuning script for qwen2-vl yet — create one following the same QLoRA pattern before spending budget on it.

Training data: `data/train/` (currently **empty** — must be populated before fine-tuning).
Options:
1. Generate synthetic training set: `uv run python data/generate_synthetic.py` (fast, free, limited diversity)
2. Generate complex layout examples: `uv run python data/generate_complex_tests.py` (targets multi-set table layout failures)
3. Download real-photo training artifacts from W&B: `uv run python scripts/download_wandb_artifact.py`

Do NOT fine-tune on the same images in `data/test/` — that's the eval set.

## Parallel agent usage

- **Safe to parallelize**: read-only tasks (error analysis per model, code review, metric inspection)
- **Never parallelize**: terraform operations — shared `terraform.tfstate` will race and corrupt
