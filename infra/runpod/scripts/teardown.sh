#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/teardown.sh [--all] [--auto-approve]

Destroys billable RunPod trainer pods while keeping the protected network volume.

Default behavior:
  terraform destroy -target=runpod_pod.trainer

Options:
  --all           Also destroy the network volume. This temporarily removes the
                  prevent_destroy lifecycle guard from main.tf, so use only when
                  checkpoints/model weights have been backed up or are disposable.
  --auto-approve  Pass -auto-approve to Terraform.
USAGE
}

DESTROY_ALL=0
AUTO_APPROVE=0
for arg in "$@"; do
  case "$arg" in
    --all) DESTROY_ALL=1 ;;
    --auto-approve) AUTO_APPROVE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APPROVE_ARGS=()
if [[ "$AUTO_APPROVE" == "1" ]]; then
  APPROVE_ARGS+=("-auto-approve")
fi

if [[ "$DESTROY_ALL" == "1" ]]; then
  cat >&2 <<'WARN'
WARNING: --all destroys the persistent RunPod network volume as well as pods.
Back up checkpoints/model weights first. This operation cannot be undone.
WARN
  if [[ "$AUTO_APPROVE" != "1" ]]; then
    read -r -p "Type destroy-volume to continue: " confirm
    [[ "$confirm" == "destroy-volume" ]] || { echo "Aborted." >&2; exit 1; }
  fi

  TMP_MAIN=$(mktemp)
  cp main.tf "$TMP_MAIN"
  cleanup() { cp "$TMP_MAIN" main.tf; rm -f "$TMP_MAIN"; }
  trap cleanup EXIT

  python3 - <<'PY'
from pathlib import Path
path = Path('main.tf')
text = path.read_text()
block = '''\n  lifecycle {\n    # Model checkpoints and downloaded weights are expensive to recreate. Remove\n    # this intentionally before destroying the volume.\n    prevent_destroy = true\n  }\n'''
if block not in text:
    raise SystemExit('Expected network volume prevent_destroy lifecycle block was not found.')
path.write_text(text.replace(block, '\n', 1))
PY
  terraform destroy "${APPROVE_ARGS[@]}"
else
  terraform destroy -target=runpod_pod.trainer "${APPROVE_ARGS[@]}"
fi
