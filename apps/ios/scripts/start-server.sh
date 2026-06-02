#!/usr/bin/env bash
# start-server.sh — Provision a RunPod GPU pod, start the API server, and create an SSH tunnel.
#
# Usage:
#   ./apps/ios/scripts/start-server.sh
#
# Environment:
#   CLOUD_TYPE    — SECURE (default) or COMMUNITY
#   GPU_TYPES     — comma-separated GPU type IDs (default: A5000, A40, 3090)
#
# After running, the server is accessible at http://localhost:8000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INFRA_DIR="$REPO_ROOT/model/infra/runpod"
MODEL_DIR="$REPO_ROOT/model"

CLOUD_TYPE="${CLOUD_TYPE:-SECURE}"
GPU_TYPES="${GPU_TYPES:-NVIDIA RTX A5000,NVIDIA A40,NVIDIA GeForce RTX 3090,NVIDIA RTX A6000}"

# Source env vars
set -a
source "$REPO_ROOT/.env" 2>/dev/null || true
set +a
export TF_VAR_ssh_public_key="${TF_VAR_ssh_public_key:-$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo '')}"
if [[ -z "${TF_VAR_ssh_public_key:-}" ]]; then
    echo "ERROR: No SSH public key found. Set TF_VAR_ssh_public_key or create ~/.ssh/id_ed25519.pub"
    exit 1
fi

echo "========================================"
echo " strg — Start Server"
echo "========================================"
echo "Cloud:     $CLOUD_TYPE"
echo "GPU types: $GPU_TYPES"
echo ""

# ── 1. Provision pod ────────────────────────────────────────────────────────
echo "--- [1/4] Provisioning pod ---"
cd "$INFRA_DIR"

# Terraform's gpu_type_ids handles fallback automatically — RunPod picks the first available
terraform apply -auto-approve \
  -var "pod_count=1" \
  -var "cloud_type=$CLOUD_TYPE" \
  -var "interruptible=true" \
  -var "ports=[\"22/tcp\", \"8888/http\", \"6006/http\", \"8000/http\"]" \
  -var "gpu_type_ids=[$(echo "$GPU_TYPES" | sed 's/,/","/g; s/^/"/; s/$/"/')]" \
  -target=runpod_pod.trainer 2>&1 | tail -5

# ── 2. Wait for IP ──────────────────────────────────────────────────────────
echo ""
echo "--- [2/4] Waiting for pod IP ---"
for i in $(seq 1 60); do
    sleep 5
    POD_DATA=$(curl -s -H "Authorization: Bearer $RUNPOD_API_KEY" \
      "https://rest.runpod.io/v1/pods" 2>/dev/null)
    IP=$(echo "$POD_DATA" | python3 -c "
import json,sys
d=json.load(sys.stdin)
pods = d.get('data', []) if isinstance(d, dict) else d
for p in (pods if isinstance(pods, list) else [pods]):
    if isinstance(p, dict) and p.get('publicIp'):
        print(p['publicIp']); break
" 2>/dev/null)
    PORT=$(echo "$POD_DATA" | python3 -c "
import json,sys
d=json.load(sys.stdin)
pods = d.get('data', []) if isinstance(d, dict) else d
for p in (pods if isinstance(pods, list) else [pods]):
    if isinstance(p, dict) and p.get('publicIp'):
        pm = p.get('portMappings', {}) or {}
        print(pm.get('22/tcp', pm.get('22', ''))); break
" 2>/dev/null)
    if [[ -n "$IP" && -n "$PORT" ]]; then
        echo "  Pod ready at ${IP}:${PORT}"
        break
    fi
    echo "  Waiting... (${i}x5s)"
done

if [[ -z "${IP:-}" || -z "${PORT:-}" ]]; then
    echo "ERROR: Pod did not get an IP address"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -p $PORT -i ~/.ssh/id_ed25519"

# ── 3. Rsync + install + start server ───────────────────────────────────────
echo ""
echo "--- [3/4] Setting up server on pod ---"

# Install rsync
ssh $SSH_OPTS root@$IP "apt-get update -qq && apt-get install -y -qq rsync" 2>&1 | tail -1

# Rsync code
rsync -az --no-owner --no-group --progress \
  --filter=':- .gitignore' \
  --exclude '.git' --exclude '__pycache__' --exclude '*.pyc' --exclude '.venv' \
  --exclude 'node_modules' --exclude 'model/infra/runpod/.terraform' \
  --exclude 'model/infra/runpod/terraform.tfstate*' --exclude 'model/infra/runpod/tfplan' \
  -e "ssh $SSH_OPTS" \
  "$REPO_ROOT/" root@${IP}:/workspace/strg/ 2>&1 | tail -1

# Install Python deps
echo "  Installing dependencies..."
ssh $SSH_OPTS root@$IP "cd /workspace/strg/model && bash scripts/runpod_install_fast.sh server 2>&1 | tail -1" 2>&1

# Download LoRA checkpoint
echo "  Downloading LoRA checkpoint..."
ssh $SSH_OPTS root@$IP "cd /workspace/strg/model && WANDB_API_KEY='$WANDB_API_KEY' .venv/bin/python -c 'import wandb; wandb.Api().artifact(\"ahnpolished-ahnpolished/strg-model/qwen2-vl-lora:latest\").download(\"checkpoints/qwen2-vl\"); print(\"  LoRA OK\")'" 2>&1

# Install serving deps
ssh $SSH_OPTS root@$IP "cd /workspace/strg/model && /usr/bin/python3 -m pip install peft bitsandbytes fastapi uvicorn python-multipart -q 2>&1 | tail -1" 2>&1

# Start server
echo "  Starting API server..."
ssh $SSH_OPTS root@$IP "cd /workspace/strg/model && STRG_QWEN_LORA_CHECKPOINT=/workspace/strg/model/checkpoints/qwen2-vl TORCH_COMPILE=0 nohup .venv/bin/python -m models_server.serve --host 0.0.0.0 --port 8000 > serve.log 2>&1 &" 2>&1

# Wait for server
echo "  Waiting for server (model load ~30s)..."
for i in $(seq 1 12); do
    sleep 5
    HEALTH=$(ssh $SSH_OPTS root@$IP "curl -s http://127.0.0.1:8000/health" 2>&1)
    DEVICE=$(echo "$HEALTH" | grep -o '"device":"[^"]*"' 2>/dev/null)
    if [[ -n "$DEVICE" ]]; then
        echo "  ✅ Server ready! $DEVICE"
        break
    fi
done

# ── 4. Print connection info ───────────────────────────────────────────────

# Create SSH tunnel so localhost:8000 works for simulator
kill $(lsof -ti tcp:8000) 2>/dev/null || true
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 -o BatchMode=yes \
  -p $PORT -i ~/.ssh/id_ed25519 \
  -L 8000:127.0.0.1:8000 -N -f root@$IP 2>/dev/null || true

echo ""
echo "========================================"
echo " ✅ Server is live!"
echo "========================================"
echo ""
echo "  📱 Simulator:"
echo "     http://localhost:8000"
echo ""
echo "  📱 Real iPhone:"
echo "     http://$IP:8000"
echo ""
echo "  ▶️  Paste this in the app's Server URL field:"
echo "     http://$IP:8000"
echo ""
echo "  🛑  Stop:  ./apps/ios/scripts/stop-server.sh"
echo "========================================"
