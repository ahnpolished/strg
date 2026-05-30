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

**Gap to close for fine-tuning target**: qwen2-vl CER 0.172 → 0.10 (−0.07), accuracy 0.776 → 0.90 (+0.12).

**Two best models confirmed**: qwen2-vl (#1) and internvl2 (#2). Debugging phase COMPLETE.

**Key failure analysis**:
- qwen2-vl: under-predicts on table layouts (photo-019: 5 pred vs 18 GT). Total: 141/156 entries.
- internvl2: over-predicts on set-countdown + grouped layouts (photos 011,014,021). Total: 202/156 entries (+57 extra!).
- internvl2 handles landscape-column layout well (photo-019: 17/18) — complementary to qwen2-vl.

**Next action**: Fine-tune qwen2-vl on compact-layout training images (data/train/). Budget spent: ~$0.23 of $10.

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
- **COMMUNITY cloud + 1 pod = capacity error (2026-05-30)**: All COMMUNITY GPU types showed "no instances available" on this date. SECURE + 1 pod at $0.44/hr succeeded. Use `--cloud-type SECURE --max-cost-per-hour 2.00` when COMMUNITY is unavailable.
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
