#!/usr/bin/env bash
set -euo pipefail

# Fast dependency install for RunPod PyTorch images.
#
# Why this exists:
# - `uv sync --all-packages` installs every workspace package, including local/iOS
#   dependencies like coremltools/moondream/pyvips that are not needed for server GPU work.
# - RunPod PyTorch images already include torch/CUDA. A normal uv-created isolated
#   venv cannot see that install, so uv may spend a long time downloading torch wheels.
#
# Usage from repo root on RunPod:
#   ./scripts/runpod_install_fast.sh              # server + evaluation workflow
#   ./scripts/runpod_install_fast.sh evaluation   # evaluation-only workflow
#   ./scripts/runpod_install_fast.sh all          # full workspace, slow fallback

MODE="${1:-server}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
PYTHON_BIN="${PYTHON_BIN:-python${PYTHON_VERSION}}"
VENV_DIR="${VENV_DIR:-.venv}"

case "$MODE" in
  server|models-server)
    # uv accepts only one --package per sync invocation, so install package
    # environments sequentially. --inexact keeps already-installed packages.
    SYNC_TARGETS=(models-server evaluation)
    ;;
  evaluation|eval)
    SYNC_TARGETS=(evaluation)
    ;;
  local|models-local)
    SYNC_TARGETS=(models-local evaluation)
    ;;
  all)
    SYNC_TARGETS=(__all__)
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Usage: $0 [server|evaluation|local|all]" >&2
    exit 2
    ;;
esac

echo "==> Ensuring Python $PYTHON_VERSION is available"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  uv python install "$PYTHON_VERSION"
  PYTHON_BIN="$(uv python find "$PYTHON_VERSION")"
fi

echo "==> Checking base image torch/CUDA with $PYTHON_BIN"
if "$PYTHON_BIN" - <<'PY'
try:
    import torch
    print("base torch:", torch.__version__)
    print("cuda available:", torch.cuda.is_available())
    print("device:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else None)
except Exception as exc:
    raise SystemExit(f"torch check failed: {exc}")
PY
then
  SKIP_TORCH=(--no-install-package torch)
else
  echo "Base image torch was not importable; uv will install torch from the lockfile." >&2
  SKIP_TORCH=()
fi

echo "==> Creating venv with system site packages: $VENV_DIR"
uv venv --system-site-packages --python "$PYTHON_BIN" "$VENV_DIR"

echo "==> Syncing mode '$MODE' with uv"
for target in "${SYNC_TARGETS[@]}"; do
  if [[ "$target" == "__all__" ]]; then
    target_args=(--all-packages)
    label="all packages"
  else
    target_args=(--package "$target")
    label="package $target"
  fi

  echo "==> Syncing $label"
  uv sync \
    --frozen \
    --no-dev \
    --inexact \
    "${target_args[@]}" \
    "${SKIP_TORCH[@]}"
done

if [[ "$MODE" != "local" && "$MODE" != "models-local" && "$MODE" != "all" ]]; then
  echo "==> Removing torchvision from the venv if present"
  # A mismatched torchvision wheel can break Transformers imports with errors
  # like `operator torchvision::nms does not exist`. Florence-2 and Qwen do not
  # need torchvision for our baseline path, so prefer absent over broken. Install
  # a matching torchvision later only if running InternVL/torchvision transforms.
  uv pip uninstall --python "$VENV_DIR/bin/python" -y torchvision >/dev/null 2>&1 || true
fi

echo "==> Verifying environment"
uv run python - <<'PY'
import sys
print("python:", sys.executable)
try:
    import torch
    print("torch:", torch.__version__)
    print("cuda available:", torch.cuda.is_available())
    print("device:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else None)
    try:
        from importlib.metadata import version

        print("torchvision installed:", version("torchvision"))
    except Exception:
        print("torchvision installed: no")
    try:
        from transformers import AutoProcessor
        print("transformers AutoProcessor: ok")
    except Exception as processor_exc:
        print("transformers AutoProcessor failed:", processor_exc)
except Exception as exc:
    print("torch import failed:", exc)
PY

echo "==> Done"
