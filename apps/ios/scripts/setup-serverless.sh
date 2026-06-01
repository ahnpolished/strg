#!/usr/bin/env bash
# setup-serverless.sh — Deploy strg-model as a RunPod Serverless endpoint via runpodctl.
#
# Usage:
#   ./apps/ios/scripts/setup-serverless.sh
#
# This script:
#   1. Downloads runpodctl (if not found)
#   2. Creates a serverless template with our Docker image
#   3. Creates a serverless endpoint from the template
#   4. Prints the endpoint URL for your app
#
# Prerequisites:
#   - RUNPOD_API_KEY in .env or exported
#   - Docker image already pushed: ghcr.io/ahnpolished/strg-model:latest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ── 0. Load env ─────────────────────────────────────────────────────────────
set -a
source "$REPO_ROOT/.env" 2>/dev/null || true
set +a

if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
    echo "❌ RUNPOD_API_KEY not set in .env or environment"
    exit 1
fi

REGISTRY="ghcr.io"
IMAGE="$REGISTRY/ahnpolished/strg-model:latest"

echo "========================================"
echo " strg — RunPod Serverless Setup"
echo "========================================"
echo ""

# ── 1. Install runpodctl ────────────────────────────────────────────────────
RCTL="/tmp/runpodctl"
if [[ ! -x "$RCTL" ]]; then
    echo "--- [1/5] Installing runpodctl ---"
    UNAME=$(uname -m)
    ARCH="amd64"
    if [[ "$UNAME" == "arm64" ]]; then ARCH="arm64"; fi
    curl -sL "https://github.com/runpod/runpodctl/releases/latest/download/runpodctl-darwin-$ARCH" -o "$RCTL"
    chmod +x "$RCTL"
    echo "  ✅ runpodctl installed"
else
    echo "--- [1/5] runpodctl already installed ---"
fi

export RUNPOD_API_KEY

# ── 2. Verify image ─────────────────────────────────────────────────────────
echo ""
echo "--- [2/5] Verifying Docker image ---"
echo "  Image: $IMAGE"

# Verify the image is accessible (should be public on ghcr.io)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://ghcr.io/v2/ahnpolished/strg-model/manifests/latest" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "401" ]]; then
    echo "  ⚠️  Image check returned HTTP $HTTP_CODE — will try to proceed"
fi

echo "  ✅ Image: $IMAGE"

# ── 3. Create serverless template ────────────────────────────────────────────
echo ""
echo "--- [3/5] Creating serverless template ---"

TEMPLATE_NAME="strg-model-$(date +%s)"
CMD="/app/model/.venv/bin/python -m models_server.serverless_worker"

TEMPLATE_ID=$($RCTL template create \
    --name "$TEMPLATE_NAME" \
    --image "$IMAGE" \
    --serverless \
    --container-disk-in-gb 20 \
    --ports "8000/http" \
    --docker-start-cmd "$CMD" \
    --env '{"HF_TOKEN":"'"${HF_TOKEN:-}"'","TORCH_COMPILE":"0","STRG_QWEN_LORA_CHECKPOINT":""}' \
    -o json 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

if [[ -z "$TEMPLATE_ID" ]]; then
    echo "  ⚠️  Template creation failed. Trying to list existing templates..."
    $RCTL template list -o json 2>&1 | python3 -c "
import json,sys
d=json.load(sys.stdin)
templates = d if isinstance(d, list) else d.get('data', d)
for t in templates:
    if isinstance(t, dict) and 'strg-model' in t.get('name','').lower():
        print(t['id']); break
" 2>/dev/null || true
    TEMPLATE_ID=$(python3 -c "
import json,sys
d=json.load(sys.stdin)
templates = d if isinstance(d, list) else d.get('data', d)
for t in templates:
    if isinstance(t, dict) and 'strg-model' in t.get('name','').lower():
        print(t['id']); break
" 2>/dev/null || echo "")
fi

if [[ -n "$TEMPLATE_ID" ]]; then
    echo "  ✅ Template ID: $TEMPLATE_ID"
else
    echo ""
    echo "  ❌ Could not create or find template."
    echo "     Create manually in RunPod Console:"
    echo "     https://www.runpod.io/console/serverless"
    echo ""
    echo "     Image: $IMAGE"
    echo "     Cmd:   $CMD"
    exit 1
fi

# ── 4. Create serverless endpoint ───────────────────────────────────────────
echo ""
echo "--- [4/5] Creating serverless endpoint ---"

GPU="NVIDIA GeForce RTX 3090"
ENDPOINT_ID=$($RCTL serverless create \
    --template-id "$TEMPLATE_ID" \
    --name "strg-model" \
    --gpu-id "$GPU" \
    --workers-min 0 \
    --workers-max 2 \
    --idle-timeout 30 \
    --flash-boot \
    -o json 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

# If first GPU type fails, try others
if [[ -z "$ENDPOINT_ID" ]]; then
    echo "  Trying alternative GPU types..."
    for GPU in "NVIDIA RTX A5000" "NVIDIA A40" "NVIDIA GeForce RTX 4090"; do
        ENDPOINT_ID=$($RCTL serverless create \
            --template-id "$TEMPLATE_ID" \
            --name "strg-model" \
            --gpu-id "$GPU" \
            --workers-min 0 \
            --workers-max 2 \
            --idle-timeout 30 \
            --flash-boot \
            -o json 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)
        if [[ -n "$ENDPOINT_ID" ]]; then
            echo "  ✅ Provisioned with $GPU"
            break
        fi
    done
fi

if [[ -z "$ENDPOINT_ID" ]]; then
    echo "  ❌ Could not create endpoint. Create manually in RunPod Console."
    exit 1
fi

echo "  ✅ Endpoint ID: $ENDPOINT_ID"

# ── 5. Print connection info ────────────────────────────────────────────────
echo ""
echo "--- [5/5] Connection info ---"
echo ""
echo "========================================"
echo " ✅ Serverless endpoint is live!"
echo "========================================"
echo ""
echo "  Endpoint ID: $ENDPOINT_ID"
echo "  GPU:         ${GPU:-unknown}"
echo ""
echo "  ▶️  Paste these in your app's fields:"
echo "     Server URL: https://api.runpod.ai/v2/$ENDPOINT_ID"
echo "     API Key:    <your RunPod API key from https://www.runpod.io/console/user/settings>"
echo ""
echo "  Test with curl:"
echo "    curl -X POST https://api.runpod.ai/v2/$ENDPOINT_ID/runsync \\"
echo "      -H \"Authorization: Bearer \$RUNPOD_API_KEY\" \\"
echo "      -H \"Content-Type: application/json\" \\"
echo "      -d '{\"input\":{\"image\":\"...base64...\"}}'"
echo ""
echo "  🛑  To stop: runpodctl serverless delete --id $ENDPOINT_ID"
echo "========================================"
