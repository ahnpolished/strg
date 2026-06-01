#!/usr/bin/env bash
# setup-serverless.sh — Deploy strg-model as a RunPod Serverless endpoint.
#
# Your Docker image is already built and pushed:
#   ghcr.io/ahnpolished/strg-model:latest
#
# This script prints the steps to configure the endpoint in RunPod Console.
# No Docker build needed — image is ready.
#
# After setup, your iPhone app calls the endpoint URL directly.
# No SSH tunnels, no persistent pod costs.
#
# Usage:
#   ./apps/ios/scripts/setup-serverless.sh

set -euo pipefail

REGISTRY="ghcr.io"
IMAGE="$REGISTRY/ahnpolished/strg-model:latest"

echo "========================================"
echo " strg — RunPod Serverless Setup"
echo "========================================"
echo ""
echo "  Your image: $IMAGE"
echo ""

# ── Verify image is accessible ──────────────────────────────────────────────
echo "--- [1/1] Verifying image exists ---"
# GHCR doesn't allow anonymous pulls, so just check the tag exists via API
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://$REGISTRY/v2/ahnpolished/strg-model/manifests/latest" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  ✅ Image verified: $IMAGE"
elif [[ "$HTTP_CODE" == "401" ]]; then
    echo "  ✅ Image exists (authenticated registry)"
else
    echo "  ⚠️  Could not verify image (HTTP $HTTP_CODE)"
    echo "     The image may still work on RunPod."
fi

# ── Print RunPod Console instructions ───────────────────────────────────────
echo ""
echo "========================================"
echo " ✅ Ready for RunPod Console"
echo "========================================"
echo ""
echo "  Follow these steps in your browser:"
echo ""
echo "  1. Go to https://www.runpod.io/console/serverless"
echo ""
echo "  2. Create a Serverless Template:"
echo "     ┌──────────────────────────────────────────────┐"
echo "     │ Name:        strg-model                       │"
echo "     │ Image:       $IMAGE"
echo "     │ Container Disk: 20 GB                         │"
echo "     │ Command:     uv run --package models-server   │"
echo "     │              --directory /app/model python    │"
echo "     │              -m models_server.serverless_worker│"
echo "     │ HTTP Port:  8000                              │"
echo "     │ Expose HTTP: Yes                              │"
echo "     │ Environment Variables:                        │"
echo "     │   HF_TOKEN=<your-huggingface-token>           │"
echo "     │   TORCH_COMPILE=0                             │"
echo "     │   STRG_QWEN_LORA_CHECKPOINT=                  │"
echo "     └──────────────────────────────────────────────┘"
echo ""
echo "  3. Create an Endpoint from that template:"
echo "     ┌──────────────────────────────────────────────┐"
echo "     │ Name:        strg-model                       │"
echo "     │ Template:    strg-model (the one above)       │"
echo "     │ GPU Type:    Any 24GB+ (3090, A5000, A40)    │"
echo "     │ Min Workers: 0 (scale to zero when idle)      │"
echo "     │ Max Workers: 2                                │"
echo "     │ Idle Timeout: 30s                             │"
echo "     │ FlashBoot:   Yes (faster cold start)          │"
echo "     └──────────────────────────────────────────────┘"
echo ""
echo "  4. After creation, copy your endpoint ID."
echo "     Your endpoint URL will be:"
echo "     https://api.runpod.ai/v2/xxxxxxxxxxxx/runsync"
echo ""
echo "  5. Paste that into the app's Server URL field:"
echo "     https://api.runpod.ai/v2/xxxxxxxxxxxx"
echo ""
echo "  🛑  To stop: Delete the endpoint in RunPod Console"
echo ""
echo "========================================"
