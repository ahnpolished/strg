#!/usr/bin/env bash
# stop-server.sh — Tear down the RunPod server pod and SSH tunnel.
#
# Usage:
#   ./apps/ios/scripts/stop-server.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INFRA_DIR="$REPO_ROOT/model/infra/runpod"

set -a
source "$REPO_ROOT/.env" 2>/dev/null || true
set +a
export TF_VAR_ssh_public_key="${TF_VAR_ssh_public_key:-$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo '')}"

echo "========================================"
echo " strg — Stop Server"
echo "========================================"

# Kill SSH tunnel
echo "--- Killing SSH tunnel ---"
kill $(lsof -ti tcp:8000) 2>/dev/null && echo "  ✅ Tunnel killed" || echo "  No tunnel found"

# Destroy pod
echo ""
echo "--- Destroying pod ---"
cd "$INFRA_DIR"
terraform destroy -auto-approve -target=runpod_pod.trainer 2>&1 | tail -1

echo ""
echo "✅ Server stopped. All clean."
