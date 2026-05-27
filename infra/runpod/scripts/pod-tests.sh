#!/usr/bin/env bash
# pod-tests.sh - End-to-end model inference + evaluation on a RunPod GPU pod.
#
# Runs on the remote pod via SSH (test-loop.sh sends this via stdin).
# Assumes:
#   - Working directory: /workspace/strg (set by test-loop.sh)
#   - RunPod PyTorch image with Python 3.11 and CUDA already present
#   - Repo has been rsynced to /workspace/strg before this runs
#
# Environment overrides (set via pod env vars in terraform.tfvars or test-loop.sh):
#   STRG_TEST_MODEL   - model to run (default: qwen2-vl)
#                       choices: qwen2-vl, internvl2, florence2, donut
#   STRG_TEST_IMAGES  - image directory (default: data/test)
#   STRG_GROUND_TRUTH - ground truth directory (default: data/test)
#   STRG_PREDICTIONS  - predictions output root (default: data/predictions)
#   WANDB_API_KEY     - if set, enables W&B logging; if unset, skips W&B
#
# Exit codes:
#   0  - inference + evaluation completed (check metric output for pass/fail)
#   1  - fatal error (install failure, import error, crash)

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace/strg}"
MODEL="${STRG_TEST_MODEL:-qwen2-vl}"
IMAGES="${STRG_TEST_IMAGES:-${WORKSPACE}/data/test}"
GROUND_TRUTH="${STRG_GROUND_TRUTH:-${WORKSPACE}/data/test}"
PREDICTIONS="${STRG_PREDICTIONS:-${WORKSPACE}/data/predictions}"

echo "==================================================================="
echo "strg model test — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  model:        $MODEL"
echo "  images:       $IMAGES"
echo "  ground truth: $GROUND_TRUTH"
echo "  predictions:  $PREDICTIONS"
echo "==================================================================="

cd "$WORKSPACE"

# ── 1. Install dependencies ─────────────────────────────────────────────────
echo ""
echo "--- [1/3] Installing dependencies ---"

if [[ ! -f scripts/runpod_install_fast.sh ]]; then
  echo "ERROR: scripts/runpod_install_fast.sh not found in $WORKSPACE" >&2
  exit 1
fi

bash scripts/runpod_install_fast.sh server

# Activate the venv created by runpod_install_fast.sh
VENV_PYTHON=".venv/bin/python"
if [[ ! -f "$VENV_PYTHON" ]]; then
  echo "ERROR: venv python not found at $VENV_PYTHON after install" >&2
  exit 1
fi

echo ""
echo "--- [1/3] Environment summary ---"
"$VENV_PYTHON" - <<'PY'
import sys, torch
print(f"python:         {sys.version.split()[0]}")
print(f"torch:          {torch.__version__}")
print(f"cuda available: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"gpu:            {torch.cuda.get_device_name(0)}")
    print(f"vram:           {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB")
PY

# ── 2. Run inference ─────────────────────────────────────────────────────────
echo ""
echo "--- [2/3] Running inference: model=$MODEL ---"

mkdir -p "$PREDICTIONS"

# Disable W&B if no API key is set (avoids interactive login prompt on pod)
if [[ -z "${WANDB_API_KEY:-}" ]]; then
  export WANDB_MODE=disabled
  echo "WANDB_API_KEY not set — W&B logging disabled."
fi

# Run model inference; --ground-truth triggers evaluation subprocess automatically
set +e
uv run python -m models_server.run \
  --model "$MODEL" \
  --images "$IMAGES" \
  --output "$PREDICTIONS" \
  --ground-truth "$GROUND_TRUTH" \
  --phase "runpod-test"
INFERENCE_EXIT=$?
set -e

if [[ $INFERENCE_EXIT -ne 0 ]]; then
  echo ""
  echo "ERROR: inference failed (exit $INFERENCE_EXIT)" >&2
  exit $INFERENCE_EXIT
fi

# ── 3. Parse and report metrics ──────────────────────────────────────────────
echo ""
echo "--- [3/3] Metric summary ---"

# The evaluation.run subprocess prints a JSON summary to stdout; extract it.
# Run evaluation standalone to get clean JSON for easy parsing.
set +e
EVAL_JSON=$(uv run python -m evaluation.run \
  --model "$MODEL" \
  --predictions "${PREDICTIONS}/${MODEL}" \
  --ground-truth "$GROUND_TRUTH" \
  --phase "runpod-test" 2>/dev/null)
EVAL_EXIT=$?
set -e

if [[ $EVAL_EXIT -ne 0 ]] || [[ -z "$EVAL_JSON" ]]; then
  echo "WARNING: could not extract evaluation metrics (exit $EVAL_EXIT)." >&2
  # Not fatal — inference may have already printed metrics
else
  echo "$EVAL_JSON"

  # Check pass/fail thresholds: CER <= 10%, macro field accuracy >= 90%
  "$VENV_PYTHON" - "$EVAL_JSON" <<'PY'
import json, sys

try:
    summary = json.loads(sys.argv[1])
except Exception as e:
    print(f"Could not parse metric JSON: {e}", file=sys.stderr)
    sys.exit(0)  # non-fatal

cer   = summary.get("avg_cer", 1.0)
acc   = summary.get("macro_field_accuracy", 0.0)
n     = summary.get("evaluated_photos", 0)

print(f"\n=== PASS/FAIL CHECK (n={n} photos) ===")
print(f"  avg CER:              {cer:.3f}  (target <= 0.10)  {'PASS' if cer <= 0.10 else 'FAIL'}")
print(f"  macro field accuracy: {acc:.3f}  (target >= 0.90)  {'PASS' if acc >= 0.90 else 'FAIL'}")

if cer <= 0.10 and acc >= 0.90:
    print("\nOVERALL: PASS")
    sys.exit(0)
else:
    print("\nOVERALL: FAIL")
    sys.exit(1)
PY
fi

echo ""
echo "==================================================================="
echo "strg model test complete — $(date '+%Y-%m-%d %H:%M:%S')"
echo "==================================================================="
