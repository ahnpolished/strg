#!/usr/bin/env bash
# update-cf-worker.sh — Update the Cloudflare Worker's serverless URL.
#
# Usage:
#   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... \
#   ./update-cf-worker.sh <new-serverless-url>
#
# Example:
#   ./update-cf-worker.sh https://api.runpod.ai/v2/abc123
#
# This updates the Worker's SERVERLESS_URL env var so your app
# always hits the stable worker URL while the backend endpoint changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../model/infra/cloudflare"

NEW_URL="${1:-}"
if [[ -z "$NEW_URL" ]]; then
    echo "Usage: $0 <new-serverless-url>"
    echo "Example: $0 https://api.runpod.ai/v2/abc123"
    exit 1
fi

# Load .env
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
set -a; source "$REPO_ROOT/.env" 2>/dev/null || true; set +a

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    echo "❌ CLOUDFLARE_API_TOKEN not set"
    echo "   Get one at https://dash.cloudflare.com/profile/api-tokens"
    echo "   Permissions needed: Account.Workers Scripts Edit"
    exit 1
fi

if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    echo "❌ CLOUDFLARE_ACCOUNT_ID not set"
    echo "   Find it at https://dash.cloudflare.com → select your account"
    exit 1
fi

cd "$TERRAFORM_DIR"

echo "========================================"
echo " Updating Cloudflare Worker"
echo "========================================"
echo "  New URL: $NEW_URL"
echo ""

terraform init -backend=false 2>&1 | tail -1

terraform apply -auto-approve \
  -var "cloudflare_api_token=$CLOUDFLARE_API_TOKEN" \
  -var "cloudflare_account_id=$CLOUDFLARE_ACCOUNT_ID" \
  -var "serverless_url=$NEW_URL" \
  -var "zone_id=${CLOUDFLARE_ZONE_ID:-}" \
  -var "custom_domain=${CLOUDFLARE_CUSTOM_DOMAIN:-}" \
  2>&1 | tail -5

WORKER_URL=$(terraform output -raw worker_url 2>/dev/null || echo "")
CUSTOM_URL=$(terraform output -raw custom_domain 2>/dev/null || echo "")

echo ""
echo "========================================"
echo " ✅ Worker updated!"
echo "========================================"
echo ""
if [[ -n "$CUSTOM_URL" ]]; then
    echo "  📱 App URL: $CUSTOM_URL"
elif [[ -n "$WORKER_URL" ]]; then
    echo "  📱 App URL: $WORKER_URL"
fi
echo ""
echo "  Paste this in your app's Server URL field"
echo "  It will always point to the current RunPod endpoint"
echo "========================================"
