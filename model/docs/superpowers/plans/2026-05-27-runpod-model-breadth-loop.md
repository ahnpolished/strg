# RunPod Model Breadth Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Broaden model evaluation beyond Qwen2-VL while making the RunPod loop trustworthy, reproducible, and safe against false passes or accidental GPU spend.

**Architecture:** Keep one single-writer/debug loop and parallelize only read-only analysis. First harden the harness so model selection and metrics are trustworthy, then run breadth experiments in priority order: InternVL2, Florence-2, Donut. Each experiment writes logs to `infra/runpod/logs/` and is judged by `avg_cer <= 0.10`, `macro_field_accuracy >= 0.90`, and sanity checks for evaluated photos/entry counts.

**Tech Stack:** Bash RunPod/Terraform scripts, Python 3.11, uv, PyTorch/CUDA, HuggingFace Transformers, Pydantic schema, W&B logging, project evaluation harness.

---

## Current state / evidence

- Latest full Qwen2-VL RunPod result: `infra/runpod/logs/iter-20260527-132959-N24.log`
  - Inference completed on 22 photos.
  - `parse_error_count = 0`.
  - `avg_cer = 0.1289768147331027`.
  - `macro_field_accuracy = 0.8550106609808102`.
  - Weak fields: `reps`, `sets`, `exercise`.
- A RunPod attempt intended for `internvl2` still ran `qwen2-vl`. Root cause: `STRG_TEST_MODEL` was not forwarded through `infra/runpod/scripts/test-loop.sh`; Terraform `TF_VAR_env` did not override existing local `terraform.tfvars` env the way expected.
- Existing 10-image local saved predictions suggest `internvl2` is the best next serious candidate:
  - `server/internvl2`: CER `0.0599`, macro accuracy `0.9133` on 10 evaluated photos.
  - Caveat: current full test set has 22 photos, so this is only a directional signal.
- Known harness risk: evaluation zips predicted/reference entries, so missing/extra rows are under-penalized. Prior N21 log also showed a false-pass class where zero predictions were not reliably surfaced as failure.
- Known InternVL2 blocker: `InternVL2Runner.predict()` imports `torchvision`, while RunPod fast install intentionally avoids/removes venv-local torchvision to prevent CUDA mismatch issues.

---

## File structure

### Modify

- `infra/runpod/scripts/test-loop.sh`
  - Responsibility: provision pod, sync repo, forward safe runtime env vars, run remote test script, tear down.
  - Planned change: forward `STRG_TEST_MODEL`, `STRG_TEST_IMAGES`, `STRG_GROUND_TRUTH`, `STRG_PREDICTIONS`, and `WANDB_API_KEY` over SSH.

- `models/server/src/models_server/internvl2.py`
  - Responsibility: InternVL2 model loading and prediction.
  - Planned change: remove `torchvision` preprocessing dependency and use PIL + torch preprocessing.

- `evaluation/src/evaluation/metrics.py`
  - Responsibility: page-level CER and field accuracy computation.
  - Planned change: add explicit missing/extra entry penalties or at least expose entry-count mismatch metrics.

- `evaluation/src/evaluation/run.py`
  - Responsibility: evaluation CLI and W&B table logging.
  - Planned change: report missing prediction count, empty page count, total reference/predicted entries, and fail-safe fields in JSON summary.

- `infra/runpod/scripts/pod-tests.sh`
  - Responsibility: remote RunPod install/inference/evaluation script.
  - Planned change: fail hard on malformed/empty metric JSON, `evaluated_photos == 0`, missing prediction files, and optionally entry-count mismatch once evaluation reports it.

### Test / verify

- `evaluation/tests/test_metrics.py`
  - Add tests for missing/extra entry penalties.

- New or inline shell dry-run checks for `infra/runpod/scripts/test-loop.sh`
  - Verify runtime env forwarding appears in dry-run logs.

- Existing local checks:
  - `uv run pytest evaluation/tests/test_metrics.py -q`
  - `uv run python - <<'PY' ... import models_server.internvl2 ... PY`
  - `bash infra/runpod/scripts/test-loop.sh --dry-run ...`

---

## Task 1: Fix model selection forwarding in the RunPod loop

**Files:**
- Modify: `infra/runpod/scripts/test-loop.sh`

- [ ] **Step 1: Write a failing dry-run check**

Run this from repo root before the fix:

```bash
set +e
LOG=/tmp/strg-test-loop-dryrun.log
OUT=/tmp/strg-test-loop.out
rm -f "$LOG" "$OUT"
RUNPOD_API_KEY=dummy \
TF_VAR_ssh_public_key=dummy \
STRG_TEST_MODEL=internvl2 \
bash infra/runpod/scripts/test-loop.sh \
  --dry-run \
  --iterations 1 \
  --log-file "$LOG" >"$OUT" 2>&1
status=$?
if grep -Fq 'STRG_TEST_MODEL=internvl2' "$LOG" "$OUT"; then
  echo 'PASS: forwarding visible'
else
  echo 'FAIL: missing STRG_TEST_MODEL forwarding'
fi
exit $status
```

Expected before fix: command exits `0`, but prints `FAIL: missing STRG_TEST_MODEL forwarding`.

- [ ] **Step 2: Implement env forwarding**

In `run_tests()` in `infra/runpod/scripts/test-loop.sh`, build a `remote_exports` string from these env vars:

```bash
WANDB_API_KEY
STRG_TEST_MODEL
STRG_TEST_IMAGES
STRG_GROUND_TRUTH
STRG_PREDICTIONS
```

Use shell-safe quoting via `printf -v remote_exports "%s export %s=%q;" ...` and prepend that to the SSH command before `cd ${REMOTE_DIR} && bash -s`.

- [ ] **Step 3: Re-run the dry-run check**

Expected after fix: prints `PASS: forwarding visible`, and the dry-run log contains `STRG_TEST_MODEL=internvl2`.

- [ ] **Step 4: Commit or checkpoint**

```bash
git add infra/runpod/scripts/test-loop.sh
git commit -m "fix(runpod): forward model selection to pod tests"
```

If not committing during the automated loop, note this as a checkpoint in the final handoff.

---

## Task 2: Make InternVL2 runnable without torchvision

**Files:**
- Modify: `models/server/src/models_server/internvl2.py`

- [ ] **Step 1: Write a failing import/helper check**

Before implementation, this should fail because `_preprocess_image` does not exist:

```bash
uv run python - <<'PY'
from PIL import Image
import torch
from models_server.internvl2 import _preprocess_image

img = Image.new('RGB', (2, 4), color=(255, 128, 0))
out = _preprocess_image(img, device=torch.device('cpu'), dtype=torch.float32)
assert out.shape == (1, 3, 448, 448), out.shape
assert out.dtype == torch.float32, out.dtype
assert out.device.type == 'cpu', out.device
print('preprocess helper works')
PY
```

Expected before fix: `ImportError: cannot import name '_preprocess_image'`.

- [ ] **Step 2: Implement PIL + torch preprocessing**

In `models/server/src/models_server/internvl2.py`:

- remove the unused `json` import;
- add `_preprocess_image(image, *, device, dtype)`;
- use `Image.Resampling.BICUBIC` resize to `448x448`;
- convert image bytes to tensor;
- reshape to `C,H,W`;
- normalize with `IMAGENET_MEAN` and `IMAGENET_STD`;
- return shape `(1, 3, 448, 448)` on the target device/dtype.

- [ ] **Step 3: Replace torchvision use in `predict()`**

Remove these imports from `predict()`:

```python
import torchvision.transforms as T
from torchvision.transforms.functional import InterpolationMode
```

Replace the transform pipeline with:

```python
image = Image.open(image_path).convert("RGB")
pixel_values = _preprocess_image(
    image,
    device=self._model.device,
    dtype=torch.bfloat16,
)
```

- [ ] **Step 4: Re-run the helper check**

Expected after fix: prints `preprocess helper works`.

- [ ] **Step 5: Import-check all server runners**

```bash
uv run python - <<'PY'
import importlib
for m in [
    'models_server.run',
    'models_server.qwen2_vl',
    'models_server.internvl2',
    'models_server.florence2',
    'models_server.donut',
]:
    importlib.import_module(m)
    print(m, 'OK')
PY
```

Expected: all imports print `OK`.

- [ ] **Step 6: Commit or checkpoint**

```bash
git add models/server/src/models_server/internvl2.py
git commit -m "fix(models): remove torchvision dependency from internvl2 preprocessing"
```

---

## Task 3: Harden evaluation against false passes

**Files:**
- Modify: `evaluation/src/evaluation/metrics.py`
- Modify: `evaluation/src/evaluation/run.py`
- Test: `evaluation/tests/test_metrics.py`

- [ ] **Step 1: Add failing tests for missing/extra entries**

Add tests that show a predicted page with fewer entries than reference is penalized and reports the mismatch.

Suggested assertions:

```python
def test_evaluate_pages_penalizes_missing_reference_entries():
    ref = WorkoutPage(entries=[entry(exercise="bench"), entry(exercise="squat")])
    pred = WorkoutPage(entries=[entry(exercise="bench")])

    result = evaluate_pages("photo1", pred, ref)

    assert result["reference_entry_count"] == 2
    assert result["predicted_entry_count"] == 1
    assert result["missing_entry_count"] == 1
    assert result["extra_entry_count"] == 0
    assert result["macro_field_accuracy"] < 1.0
    assert result["avg_cer"] > 0.0
```

Add a matching test for extra predicted entries.

Expected before implementation: `KeyError` for the new result fields or incorrect metrics.

- [ ] **Step 2: Implement count-aware scoring**

In `evaluate_pages()`:

- compute `predicted_entry_count`, `reference_entry_count`, `missing_entry_count`, `extra_entry_count`;
- keep current row comparisons for aligned `zip()` pairs;
- for each missing reference entry, add CER comparing `""` to the reference text and add one false row for each field;
- for each extra predicted entry, add CER comparing predicted text to `""` and add one false row for each field;
- return the new count fields in the result dict.

This preserves current exact-match behavior for aligned entries while making missing/extra rows visible and costly.

- [ ] **Step 3: Update `evaluation.run` summary**

Aggregate and print:

```python
missing_prediction_count
empty_prediction_count
total_reference_entries
total_predicted_entries
missing_entry_count
extra_entry_count
```

Keep existing fields unchanged for W&B/backward compatibility.

- [ ] **Step 4: Run tests**

```bash
uv run pytest evaluation/tests/test_metrics.py -q
```

Expected: all tests pass.

- [ ] **Step 5: Re-evaluate existing saved predictions with W&B disabled**

```bash
WANDB_MODE=disabled uv run python -m evaluation.run \
  --model server/internvl2 \
  --predictions data/predictions/server/internvl2 \
  --ground-truth data/test \
  --phase local-audit
```

Expected: JSON includes the new count fields and `evaluated_photos > 0`.

- [ ] **Step 6: Commit or checkpoint**

```bash
git add evaluation/src/evaluation/metrics.py evaluation/src/evaluation/run.py evaluation/tests/test_metrics.py
git commit -m "fix(evaluation): penalize missing and extra workout entries"
```

---

## Task 4: Harden remote pass/fail checks in `pod-tests.sh`

**Files:**
- Modify: `infra/runpod/scripts/pod-tests.sh`

- [ ] **Step 1: Add shell-level checks to the metric parser**

After `EVAL_JSON` extraction, fail if:

- `EVAL_EXIT != 0`;
- `EVAL_JSON` is empty;
- JSON cannot be parsed;
- `evaluated_photos == 0`;
- `missing_prediction_count > 0`;
- `empty_prediction_count > 0`;
- optionally, `missing_entry_count > 0` or `extra_entry_count > 0` if we decide exact row counts are mandatory.

- [ ] **Step 2: Dry-run / static shell check**

```bash
bash -n infra/runpod/scripts/pod-tests.sh
```

Expected: no syntax errors.

- [ ] **Step 3: Commit or checkpoint**

```bash
git add infra/runpod/scripts/pod-tests.sh
git commit -m "fix(runpod): fail on invalid or incomplete eval output"
```

---

## Task 5: Run InternVL2 full RunPod breadth experiment

**Files:**
- Logs: `infra/runpod/logs/iter-YYYYMMDD-HHMMSS-N*-internvl2.log`

- [ ] **Step 1: Verify no tracked pod exists**

```bash
terraform -chdir=infra/runpod state list | sort
```

Expected when idle: only `runpod_network_volume.model_weights`.

- [ ] **Step 2: Load secrets without printing them**

```bash
set -a
[ -f .env ] && source .env
set +a
if [[ -z "${TF_VAR_ssh_public_key:-}" ]]; then
  export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub)"
fi
```

- [ ] **Step 3: Run one InternVL2 iteration**

```bash
mkdir -p infra/runpod/logs
LOG_FILE="$(pwd)/infra/runpod/logs/iter-$(date '+%Y%m%d-%H%M%S')-N-internvl2.log"
STRG_TEST_MODEL=internvl2 \
bash infra/runpod/scripts/test-loop.sh \
  --iterations 1 \
  --iteration-timeout 1800 \
  --log-file "$LOG_FILE"
```

Expected: remote log header says `model: internvl2`.

- [ ] **Step 4: Classify result**

From the log, record:

- exit code;
- category: infra/install/import/inference/evaluation/timeout;
- `avg_cer`;
- `macro_field_accuracy`;
- field accuracy;
- parse errors;
- evaluated photos;
- missing/extra entry counts if available;
- W&B run URL if W&B is enabled.

- [ ] **Step 5: Decide next action**

- If InternVL2 passes: stop and report final result.
- If import/install fails: debug root cause from traceback before any fix.
- If inference/eval completes but misses thresholds: inspect W&B table and prediction JSON for worst fields/photos.
- If row-count failure dominates: improve prompt/model-specific normalization only after documenting examples.

---

## Task 6: Run Florence-2 smoke/breadth experiment

**Files:**
- Modify only if required: `models/server/src/models_server/florence2.py`
- Logs: `infra/runpod/logs/*-florence2.log`

- [ ] **Step 1: Run Florence-2 once**

```bash
LOG_FILE="$(pwd)/infra/runpod/logs/iter-$(date '+%Y%m%d-%H%M%S')-N-florence2.log"
STRG_TEST_MODEL=florence2 \
bash infra/runpod/scripts/test-loop.sh \
  --iterations 1 \
  --iteration-timeout 1800 \
  --log-file "$LOG_FILE"
```

- [ ] **Step 2: Classify result**

Expected likely outcome: model runs but parser quality is below target.

- [ ] **Step 3: If parser fixes are warranted, use TDD first**

Known likely fixes:

- do not default missing dates to `today()`;
- set `weight_lbs` for lbs instead of converting to kg;
- reduce debug noise;
- add empty OCR diagnostics.

---

## Task 7: Run Donut smoke/breadth experiment

**Files:**
- Modify only if required: `models/server/src/models_server/donut.py`
- Possibly modify: `models/server/pyproject.toml`, `uv.lock` if tokenizer dependency is missing.
- Logs: `infra/runpod/logs/*-donut.log`

- [ ] **Step 1: Run Donut once**

```bash
LOG_FILE="$(pwd)/infra/runpod/logs/iter-$(date '+%Y%m%d-%H%M%S')-N-donut.log"
STRG_TEST_MODEL=donut \
bash infra/runpod/scripts/test-loop.sh \
  --iterations 1 \
  --iteration-timeout 1800 \
  --log-file "$LOG_FILE"
```

- [ ] **Step 2: Classify result**

Expected likely outcome: tokenizer/parser failure or poor zero-shot JSON quality.

- [ ] **Step 3: If parser fixes are warranted, use TDD first**

Known likely fixes:

- include `weight_lbs` in the prompt;
- reuse Qwen JSON extraction/normalization;
- add `sentencepiece` only if the traceback proves it is missing.

---

## Task 8: Report and choose winner / next experiment

**Files:**
- Create or update: `infra/runpod/logs/summary-YYYYMMDD.md` or final assistant handoff.

- [ ] **Step 1: Build summary table**

Columns:

```text
model | log file | status | evaluated_photos | parse_errors | avg_cer | macro_acc | weakest_fields | notes
```

- [ ] **Step 2: Include W&B links**

For runs with W&B enabled, include run URLs from logs.

- [ ] **Step 3: Recommend next move**

Decision rules:

- If a model passes both metrics with hardened evaluator: stop and declare candidate.
- If InternVL2 is closest: focus prompt/normalization on its worst fields.
- If all zero-shot models fail by row count: prioritize fine-tuning / better image row segmentation rather than more prompt tweaks.
- If harness is still suspect: do not spend more GPU until it is fixed.

---

## Validation contract

Before calling the loop trustworthy:

- `STRG_TEST_MODEL=internvl2` dry-run visibly forwards to remote command.
- `models_server.internvl2` imports locally without requiring torchvision.
- `evaluation/tests/test_metrics.py` passes.
- `evaluation.run` reports nonzero evaluated photos and entry-count diagnostics.
- `pod-tests.sh` fails on zero evaluated photos / missing predictions / malformed JSON.
- Every RunPod run has a log under `infra/runpod/logs/` and teardown succeeds.
- Final pass requires both:
  - `avg_cer <= 0.10`
  - `macro_field_accuracy >= 0.90`

---

## Current uncommitted work note

Before this plan was requested, two implementation changes had already been started:

- `infra/runpod/scripts/test-loop.sh`: env forwarding for `STRG_TEST_MODEL` and related runtime vars.
- `models/server/src/models_server/internvl2.py`: `_preprocess_image()` helper replacing `torchvision` preprocessing.

These should be validated against Task 1 and Task 2 before any further RunPod spend.
