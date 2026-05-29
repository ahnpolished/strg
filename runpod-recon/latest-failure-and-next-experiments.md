# RunPod reconnaissance: latest failure and next experiments

Date: 2026-05-27  
Scope: read-only inspection of `infra/runpod/scripts`, `infra/runpod/logs`, server model runners, evaluation metrics, Terraform safety config, and current git diff. I did not modify project/source files; this report is the only written artifact.

## Executive summary

The latest full RunPod loop is **`infra/runpod/logs/iter-20260527-132959-N24.log`**. It is not an infra/install/import crash: provisioning, SSH, rsync, dependency install, Qwen2-VL inference, evaluation, and teardown all ran. The exact latest failure mode is **evaluation failure / low extraction accuracy**:

- Model: `qwen2-vl` (`infra/runpod/logs/iter-20260527-132959-N24.log:536`).
- GPU: H100 80GB, CUDA available (`...N24.log:530-534`).
- Inference completed on all 22 photos with `parse_error_count: 0` (`...N24.log:588-593`).
- Metric failure (`...N24.log:597-618`):
  - `avg_cer = 0.1289768147331027` > target `0.10`
  - `macro_field_accuracy = 0.8550106609808102` < target `0.90`
  - weakest fields: `reps = 0.7313`, `sets = 0.7836`, `exercise = 0.8657`
  - `OVERALL: FAIL`; test script exited 1.
- Terraform teardown succeeded; current Terraform state lists only `runpod_network_volume.model_weights`.

The model is mostly failing semantically, especially by **collapsing physical repeated rows into grouped sets / missing rows** and making set-rep mistakes on dense pages. This is partially hidden by the evaluator, which currently zips predicted/reference entries and does not directly penalize missing/extra entries.

## Latest log evidence

### Latest run: N24

Key lines from `infra/runpod/logs/iter-20260527-132959-N24.log`:

- SSH and pod readiness:
  - `:103` `Pod reachable at 103.207.149.105:15278`
  - `:104` `SSH ready: root@103.207.149.105:15278`
- Environment:
  - `:530-534` Python 3.11.10, torch 2.4.1+cu124, CUDA true, GPU `NVIDIA H100 80GB HBM3`, 85.0 GB VRAM.
- Inference:
  - `:536` `--- [2/3] Running inference: model=qwen2-vl ---`
  - `:588-593` summary: `photos_evaluated: 22`, `parse_error_count: 0`, `peak_vram_gb: 22.88314112`.
- Metrics:
  - `:597` `avg_cer: 0.1289768147331027`
  - `:598` `macro_field_accuracy: 0.8550106609808102`
  - `:600-606` per-field accuracy: date 0.8806, exercise 0.8657, sets 0.7836, reps 0.7313, weight_kg 0.8881, weight_lbs 0.9328, notes 0.9030.
  - `:613-618` threshold check fails both CER and macro accuracy; `OVERALL: FAIL`; `Tests FAILED on iteration 1 (exit 1)`.

Observed per-photo count problems in N24:

- Ground-truth counts from `data/test/*.json`: `019` has 18 entries, `022` has 11, `017` has 14, `013` has 9.
- N24 predicted counts from log:
  - `019`: 5 entries (`...N24.log:617`) vs 18 GT entries in `data/test/019.json`.
  - `022`: 9 entries (`...N24.log:620-621` area) vs 11 GT entries in `data/test/022.json`.
  - `017`: 12 entries (`...N24.log:613`) vs 14 GT entries in `data/test/017.json`.
  - `013`: 6 entries (`...N24.log:604`) vs 9 GT entries in `data/test/013.json`.
- Example raw output evidence:
  - `...N24.log:600` for photo `010`: model emits `sets: 2`, `reps: 3`, `weight_kg: 225`, `weight_lbs: 500` for a lbs bench page; GT in `data/test/011.json`-style lbs pages expects single physical rows and `weight_lbs` only. Current normalizer can correct some kg/lbs conflict, but not grouped set/reps.
  - `...N24.log:618-619` for photo `019`: raw output starts as a bare JSON array and then only 5 entries are counted for an 18-entry page.

### Previous runs show harness/metric hazards

- `infra/runpod/logs/iter-20260527-131558-N23.log` was numerically closest to passing but is misleading:
  - Metrics: `avg_cer = 0.10463044811226346`, `macro_field_accuracy = 0.8928571428571429` (`...N23.log:594-615`).
  - However photo `022` produced `0 entries, error=False` (`...N23.log:580-582`). Because the evaluator zips entries and a zero-entry page contributes no field rows and `avg_cer=0`, missing whole pages can under-penalize results.
- `infra/runpod/logs/iter-20260527-125844-N21.log` shows a false-pass risk:
  - `photos_evaluated: 0`, `parse_error_count: 0` (`...N21.log:498-499`).
  - All 22 GT files warn `No prediction found` (`...N21.log:529-550`).
  - Evaluation reports `evaluated_photos: 0` (`...N21.log:552-565`) and `Could not parse metric JSON` (`...N21.log:567`), but the loop still logged `Tests PASSED on iteration 1` (`...N21.log:572`).

## Relevant code paths and constraints

### RunPod loop scripts

- `infra/runpod/scripts/test-loop.sh`
  - Polls RunPod REST for public IP/SSH port and validates SSH (`lines 262-310`).
  - Rsync includes test images and excludes `.git`, `.venv`, terraform state/plan, and `data/train` (`lines 336-349`).
  - Always tears down after test execution unless teardown itself fails (`run_once`, `lines 381+`).
- `infra/runpod/scripts/pod-tests.sh`
  - Defaults model to `qwen2-vl` (`line 25`).
  - Runs `scripts/runpod_install_fast.sh server` (`line 59`).
  - Runs inference via `python -m models_server.run --output $PREDICTIONS` (`lines 97-103`).
  - Runs evaluation separately and enforces thresholds (`lines 119-168`): `avg_cer <= 0.10` and `macro_field_accuracy >= 0.90`; `n == 0` is intended to fail (`lines 160-162`), but N21 shows the surrounding JSON extraction / shell behavior is not fully safe.

### Model runner behavior

- `models/server/src/models_server/qwen2_vl.py`
  - Current local diff adds output normalization and JSON recovery (`lines 14-152`): date normalization, list-to-scalar coercion, weight conflict handling, note bracket stripping, bare-array parsing, truncated-output recovery.
  - Qwen loads `Qwen/Qwen2-VL-7B-Instruct` with `torch_dtype=torch.bfloat16`, `device_map="auto"` (`lines 155-164`).
  - Generation uses `max_new_tokens=2048` but no explicit `do_sample=False`, beams, or `use_fast=False` processor setting (`lines 158-184`). The latest log warns the Qwen image processor is now fast by default and may produce slightly different outputs (`...N24.log:537`).
- `models/server/src/models_server/prompt.py`
  - Current prompt already emphasizes every physical row and non-merged rows (`lines 19-27`). N24 still collapses/misses rows, so the next prompt experiment should be more structural than another small wording tweak.
- `models/server/src/models_server/internvl2.py`
  - Current diff reuses Qwen JSON extraction/normalization and raises `max_new_tokens` to 2048.
  - But `predict()` imports `torchvision.transforms`; `scripts/runpod_install_fast.sh` removes `torchvision` for server mode, so InternVL2 will likely fail unless install behavior changes.
- `models/server/src/models_server/florence2.py`
  - Florence-2 path is OCR plus a heuristic parser. Likely useful as OCR/row-count diagnostic, but the parser is too simple for the current schema unless improved.
- `models/server/src/models_server/donut.py`
  - Donut is zero-shot DocVQA JSON; likely lower priority than Qwen unless used as a smoke test.

### Evaluation behavior

- `evaluation/src/evaluation/metrics.py`
  - `evaluate_pages()` uses `zip(predicted.entries, reference.entries)` (`line 35`), so extra/missing entries are not directly scored.
  - If no entries are compared, `avg_cer` becomes `0.0` and per-field accuracies become `0.0` (`lines 53-56`), but missing-page impact is weak in aggregate.
- `evaluation/src/evaluation/run.py`
  - Missing prediction files are skipped with a warning (`lines 32-37`).
  - Summary `evaluated_photos` is `len(all_cer)` (`line 62`), which counts pages with a prediction file even if that prediction contains zero entries.

## Current git/worktree state

`git status --short` shows modified source files:

- `.claude/commands/runpod-loop.md`
- `models/server/src/models_server/internvl2.py`
- `models/server/src/models_server/prompt.py`
- `models/server/src/models_server/qwen2_vl.py`
- `packages/common/src/common/schema.py`
- `scripts/runpod_install_fast.sh`
- `.claude/worktrees/fix-moondream-transformers5` shows as modified/submodule-ish entry
- untracked `infra/runpod/tfplan`

Important diff already present:

- Qwen parser now handles bare arrays and truncated JSON; normalizer handles nullable dates, list fields, weight conflicts, and note brackets.
- Prompt now strongly tells the model to count every physical row and avoid merging rows.
- Schema now allows `date: None`.
- RunPod install now installs `uv`, uses `/workspace/.uv-cache`, skips many CUDA packages, and verifies using `.venv/bin/python` instead of `uv run`.

Ignored local config/log state:

- `infra/runpod/terraform.tfvars` is ignored but currently has `pod_count = 1`, premium GPUs (`A100/H100/H100 NVL/L40S`), `attach_network_volume = false`, `interruptible = false`, `cloud_type = SECURE`, image `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04`.
- Current Terraform state list is only `runpod_network_volume.model_weights`, so no pod appears to be tracked right now.

## Best next experiments

1. **Fix/guard the evaluator before trusting another “pass”.**
   - Add direct penalties for missing/extra entries or at least report and fail on entry-count mismatch.
   - Make `evaluated_photos == 0`, parse failures, or metric-JSON parse errors reliably nonzero in `pod-tests.sh`.
   - Reason: N21 logged a pass with zero predictions; N23 got near-pass despite photo `022` producing zero entries.

2. **Run Qwen2-VL with deterministic/stable generation and processor settings.**
   - Set `AutoProcessor.from_pretrained(..., use_fast=False)` to remove the logged processor behavior change.
   - Make generation explicit: `do_sample=False` (and consider `num_beams=1` first for speed/reproducibility).
   - Keep `max_new_tokens=2048`; parse errors are currently zero in N24.
   - Goal: reduce N23/N24 variance and make metrics comparable.

3. **Prompt experiment focused on row enumeration, not generic schema text.**
   - Ask for an intermediate mental step: read top-to-bottom and output one JSON entry per visible row in order.
   - Explicitly say: repeated physical rows must be duplicated as separate JSON objects even if exercise/weight are identical; only use `sets > 1` when the written row itself contains a set multiplier like `3x10`.
   - Add lbs examples matching pages `010/011/022`: “225 x 5” with no kg marker is pounds only if the page uses lbs; do not create both kg and lbs.
   - Primary metric targets: `sets` and `reps`, currently the weakest fields in N24.

4. **Use Florence-2/OCR as a diagnostic, not immediate pass candidate.**
   - Run/inspect OCR text on hard pages (`019`, `022`, `017`) to see whether row boundaries are legible. If OCR sees all rows, Qwen prompt/parse is the issue; if OCR also misses rows, image/model capacity is the issue.

5. **Only try InternVL2 after install compatibility is fixed.**
   - Current server install removes `torchvision`, but InternVL2 imports it in `predict()`. Running it now likely shifts the failure mode to `ModuleNotFoundError` rather than model quality.

6. **Consider a stronger Qwen family model only after harness fixes.**
   - H100 memory headroom is large (Qwen2-VL-7B peak ~22.9 GB in N24), so a larger/newer VLM experiment may fit. But without entry-count penalties, model comparisons can be misleading.

## Safety constraints / operational risks

- **Cost:** `infra/runpod/terraform.tfvars` currently sets `pod_count = 1` and premium GPUs. A plain `terraform apply` from `infra/runpod` could create an expensive pod even though state currently has no pod. Use `-var pod_count=0` or reset tfvars when idle.
- **Teardown:** Latest loop did tear down the pod; Terraform state now lists only the persistent network volume.
- **Storage durability:** `attach_network_volume = false`; `/workspace` caches/checkpoints are not the protected network volume in this mode. Do not rely on pod `/workspace` surviving destroy.
- **Validation:** Current evaluator under-penalizes missing rows/pages and previously allowed a false pass; treat any pass before harness hardening as suspect.
- **Secrets:** Logs/config should not expose or commit API keys. `terraform.tfvars`, state, and logs are ignored; keep them that way.
