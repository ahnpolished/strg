---
description: "RunPod iterative test loop: provision pod → run model inference+eval → analyze logs → fix code → repeat. Loops until models pass CER<=10% and field accuracy>=90%, or until stopped."
allowed-tools: Bash, Read, Edit, Write
---

# RunPod Improvement Loop

You are running an autonomous improvement loop for ML model evaluation on RunPod GPU pods. Your job: provision, test, analyze failures, fix code, and repeat until the model evaluation passes.

## Arguments
$ARGUMENTS — optional. Examples:
- `qwen2-vl` — test a specific server model (choices: qwen2-vl, internvl2, florence2, donut)
- `--model florence2 --iterations 5` — model + max iterations before stopping
- `--dry-run` — verify the loop works without spending GPU credits

Parse `$ARGUMENTS` to extract `--model MODEL` (default: qwen2-vl) and `--iterations N` (default: 0 = loop forever until pass). Pass `--dry-run` through if present.

## Setup

Before the first iteration:

1. Verify required env vars are set:
   ```bash
   echo "RUNPOD_API_KEY=${RUNPOD_API_KEY:0:8}..."
   echo "TF_VAR_ssh_public_key=${TF_VAR_ssh_public_key:0:20}..."
   ```
   If missing:
   ```bash
   # RUNPOD_API_KEY must already be set (used by Terraform provider too)
   export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub)"
   ```

2. Create the log directory:
   ```bash
   mkdir -p infra/runpod/logs
   ```

3. If a model was specified in `$ARGUMENTS`, export it so the pod picks it up:
   ```bash
   export TF_VAR_env='{"STRG_TEST_MODEL":"<model>"}'
   ```
   This merges into the pod's env via `main.tf`'s `env = merge(...)`.

## Iteration loop

For each iteration N (starting at 1):

### Step 1 — Run one test iteration

Set up iteration log file (use absolute path from repo root):
```bash
LOG_FILE="$(pwd)/infra/runpod/logs/iter-$(date '+%Y%m%d-%H%M%S')-N${ITER}.log"
```

Run the loop (from repo root) with 20-minute hard timeout:
```bash
bash infra/runpod/scripts/test-loop.sh \
  --iterations 1 \
  --iteration-timeout 1200 \
  --log-file "$LOG_FILE" \
  [--dry-run if applicable]
```

Capture the exit code.

### Step 2 — Read and analyze the log

```bash
cat "$LOG_FILE"
```

Classify the result into one of these categories:

**A. INFRASTRUCTURE FAILURE** (provision/SSH failed)
- Signs: `terraform apply` errors, "no instances available", SSH timeout
- Fix actions:
  - If "no instances available": in `infra/runpod/terraform.tfvars`, try adding more GPU fallbacks to `gpu_type_ids`, set `attach_network_volume = false`, set `interruptible = false`
  - If SSH timeout: check `support_public_ip = true` and `"22/tcp"` in ports

**B. INSTALL FAILURE** (dependency install crashed)
- Signs: pip/uv errors, missing packages, build failures
- Fix actions: read the full error, edit `scripts/runpod_install_fast.sh` or `pyproject.toml` for the affected package

**C. IMPORT / CODE ERROR** (Python crash before inference runs)
- Signs: `ImportError`, `ModuleNotFoundError`, `AttributeError` in model runner
- Fix actions: read the traceback, identify the file (e.g., `models/server/src/models_server/qwen2_vl.py`), fix the import or API mismatch
- Key model files:
  - `models/server/src/models_server/qwen2_vl.py`
  - `models/server/src/models_server/florence2.py`
  - `models/server/src/models_server/internvl2.py`
  - `models/server/src/models_server/donut.py`
  - `models/server/src/models_server/base.py`
  - `models/server/src/models_server/prompt.py`

**D. INFERENCE FAILURE** (model loaded but crashed during inference)
- Signs: CUDA OOM, shape mismatch, generation errors
- Fix actions:
  - OOM: reduce batch size in the runner, try a smaller model
  - Generation errors: check prompt template in `prompt.py`, fix parsing logic

**E. EVALUATION FAILURE / LOW METRICS** (inference ran, metrics below threshold)
- Signs: `OVERALL: FAIL`, `avg_cer > 0.10`, `macro field accuracy < 0.90`, parse errors
- The JSON metric summary will be in the log. Look at per-field accuracy to find weak fields.
- Fix actions:
  - High parse errors: fix JSON parsing in `base.py` or the model runner's `parse_output()` method
  - Low accuracy on specific fields (e.g., `reps`, `weight`): improve the prompt in `prompt.py`
  - High CER: prompt refinement, check if model output format matches expected schema

**F. TIMEOUT** (exit code 124, ran over 30 minutes)
- Signs: `HARD TIMEOUT: iteration exceeded 1800s`
- Fix actions: check what step was slow in the log; if inference is slow, the model may be too large for the GPU — try `florence2` or `donut` as faster alternatives

### Step 3 — Fix the code

Based on the failure category, make targeted edits. Be surgical: fix one issue at a time.

After each edit, briefly note what you changed and why (for the next iteration's context).

### Step 4 — Decide whether to continue

- If **PASS** (exit 0 AND `OVERALL: PASS` in log): declare success and stop.
- If **max iterations reached**: stop and report final state.
- Otherwise: go to Step 1 with iter+1.

## Reporting

After each iteration, output a concise summary:
```
Iteration N: <PASS|FAIL|TIMEOUT|INFRA_FAIL>
  Exit code: X
  Category: [A-F above]
  Metrics: CER=X.XXX, accuracy=X.XXX  (if available)
  Fix applied: <one-line description>
```

At the end of the loop (pass or stop), output:
```
=== Loop complete ===
Total iterations: N
Final result: PASS / FAIL / STOPPED
Final metrics: CER=X.XXX, accuracy=X.XXX
```

## Key files reference

| File | Purpose |
|------|---------|
| `infra/runpod/scripts/pod-tests.sh` | Commands run on pod; edit to change what's tested |
| `infra/runpod/terraform.tfvars` | GPU type, pod count, env vars |
| `models/server/src/models_server/<model>.py` | Model runner — fix inference bugs here |
| `models/server/src/models_server/prompt.py` | Prompt template — fix output format here |
| `models/server/src/models_server/base.py` | Base runner, JSON parsing — fix parse errors here |
| `evaluation/src/evaluation/metrics.py` | Metric computation |
| `packages/common/src/common/schema.py` | WorkoutPage/WorkoutEntry schema |
| `scripts/runpod_install_fast.sh` | Pod dependency install |

## Success criteria (from CLAUDE.md)

- `avg_cer <= 0.10` (Character Error Rate)
- `macro_field_accuracy >= 0.90` (exact-match accuracy across all fields)

Both must pass simultaneously. Fields: exercise, sets, reps, weight, unit, notes.
