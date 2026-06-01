#!/usr/bin/env bash
# serverless-test-loop.sh — Automate serverless deployment and testing.
#
# Full cycle:
#   1. Push current code (if --push)
#   2. Wait for GHA Docker build to finish
#   3. Create/update RunPod serverless endpoint
#   4. Wait for worker to be ready (poll health/runsync)
#   5. Test with a real image
#   6. Repeat if it fails (with --loop)
#
# Usage:
#   ./apps/ios/scripts/serverless-test-loop.sh              # deploy only
#   ./apps/ios/scripts/serverless-test-loop.sh --loop       # keep trying
#   ./apps/ios/scripts/serverless-test-loop.sh --max 10     # max 10 attempts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RCTL="/tmp/runpodctl"
TEST_IMAGE="$REPO_ROOT/model/data/test/001.jpg"
IMAGE="ghcr.io/ahnpolished/strg-model:latest"
MAX_ATTEMPTS=20
SLEEP_BETWEEN=10
LOOP=false

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --loop) LOOP=true; shift ;;
        --max) MAX_ATTEMPTS="$2"; shift 2 ;;
        --test-image) TEST_IMAGE="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# ── 0. Setup ────────────────────────────────────────────────────────────────
set -a
source "$REPO_ROOT/.env" 2>/dev/null || true
set +a

if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
    echo "❌ RUNPOD_API_KEY not set"
    exit 1
fi
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "⚠️  GITHUB_TOKEN not set — will skip GHA status check"
fi

export RUNPOD_API_KEY

# Install runpodctl
if [[ ! -x "$RCTL" ]]; then
    UNAME=$(uname -m)
    ARCH="amd64"
    [[ "$UNAME" == "arm64" ]] && ARCH="arm64"
    curl -sL "https://github.com/runpod/runpodctl/releases/latest/download/runpodctl-darwin-$ARCH" -o "$RCTL"
    chmod +x "$RCTL"
fi

# ── Helper functions ────────────────────────────────────────────────────────

check_gha_status() {
    # Return 0 if latest GHA workflow for main succeeded
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        echo "  [GHA] No token — assuming build is ready"
        return 0
    fi
    local status
    status=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
        "https://api.github.com/repos/ahnpolished/strg/actions/runs?branch=main&event=push&per_page=1" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); runs=d.get('workflow_runs',[]); print(runs[0]['conclusion'] if runs else 'unknown')" 2>/dev/null || echo "unknown")

    case "$status" in
        success) return 0 ;;
        failure) echo "  [GHA] Last workflow failed!" >&2; return 1 ;;
        *)       echo "  [GHA] Status: $status (waiting...)"; return 1 ;;
    esac
}

wait_for_gha() {
    echo ""
    echo "--- Waiting for GHA Docker build ---"
    for i in $(seq 1 60); do
        if check_gha_status; then
            echo "  ✅ GHA build complete"
            return 0
        fi
        sleep 10
    done
    echo "  ⚠️  GHA timeout — proceeding anyway"
    return 1
}

create_or_get_endpoint() {
    local template_id endpoint_id

    # Create template
    local tpl_name="strg-model-test-$(date +%s)"
    echo ""
    echo "--- Creating serverless template ---"
    template_id=$($RCTL template create \
        --name "$tpl_name" \
        --image "$IMAGE" \
        --serverless \
        --container-disk-in-gb 20 \
        --ports "8000/http" \
        --env '{"HF_TOKEN":"'"${HF_TOKEN:-}"'","TORCH_COMPILE":"0"}' \
        -o json 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

    if [[ -z "$template_id" ]]; then
        echo "  ❌ Template creation failed"
        return 1
    fi
    echo "  ✅ Template: $template_id"

    # Create endpoint
    echo ""
    echo "--- Creating serverless endpoint ---"
    local gpu="NVIDIA GeForce RTX 3090"
    endpoint_id=$($RCTL serverless create \
        --template-id "$template_id" \
        --name "strg-test-$(date +%s)" \
        --gpu-id "$gpu" \
        --workers-min 1 \
        --workers-max 1 \
        --idle-timeout 60 \
        --flash-boot \
        -o json 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

    # Fallback GPUs
    if [[ -z "$endpoint_id" ]]; then
        for gpu in "NVIDIA RTX A5000" "NVIDIA A40" "NVIDIA GeForce RTX 4090"; do
            endpoint_id=$($RCTL serverless create \
                --template-id "$template_id" \
                --name "strg-test-$(date +%s)" \
                --gpu-id "$gpu" \
                --workers-min 1 \
                --workers-max 1 \
                --idle-timeout 60 \
                --flash-boot \
                -o json 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)
            [[ -n "$endpoint_id" ]] && break
        done
    fi

    if [[ -z "$endpoint_id" ]]; then
        echo "  ❌ Endpoint creation failed"
        return 1
    fi
    echo "  ✅ Endpoint: $endpoint_id"
    echo "$endpoint_id"
    return 0
}

test_endpoint() {
    local endpoint_id="$1"
    local run_url="https://api.runpod.ai/v2/$endpoint_id/run"
    local status_url="https://api.runpod.ai/v2/$endpoint_id/status"

    echo ""
    echo "--- Testing endpoint ---"

    # Encode test image as base64 (small image for fast test)
    local img_b64
    img_b64=$(base64 -i "$TEST_IMAGE" 2>/dev/null || base64 "$TEST_IMAGE")

    # 1. Submit async job (don't wait long)
    echo "  Submitting predict (async)..."
    local submit
    submit=$(curl -s -X POST "$run_url" \
        -H "Authorization: Bearer $RUNPOD_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"input\":{\"image\":\"$img_b64\",\"filename\":\"photo.jpg\"}}" \
        --max-time 30 2>&1)

    local job_id
    job_id=$(echo "$submit" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")
    
    if [[ -z "$job_id" ]]; then
        echo "  ❌ Failed to submit: $(echo "$submit" | head -1)"
        return 1
    fi
    echo "  Job ID: $job_id"

    # 2. Poll status until complete
    echo "  Waiting for result (model cold start may take 2-5min)..."
    for i in $(seq 1 60); do
        sleep 10
        local status
        status=$(curl -s -X POST "$status_url/$job_id" \
            -H "Authorization: Bearer $RUNPOD_API_KEY" \
            -H "Content-Type: application/json" \
            --max-time 10 2>&1)

        local state
        state=$(echo "$status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
        
        case "$state" in
            COMPLETED) 
                echo ""
                echo "  Response:"
                echo "$status" | python3 -c "
import json,sys
d=json.load(sys.stdin)
o=d.get('output',{})
print(f'    Entries: {o.get(\"entry_count\",\"?\")}  Latency: {o.get(\"latency_s\",\"?\")}s')
for e in o.get('entries',[])[:3]:
    print(f'      {e[\"exercise\"]}: {e[\"sets\"]}x{e[\"reps\"]}')
" 2>/dev/null
                echo ""
                echo "  ✅ Prediction succeeded!"
                return 0
                ;;
            FAILED)
                echo "  ❌ Job failed: $status"
                return 1
                ;;
            IN_PROGRESS|IN_QUEUE)
                echo "  [$((i*10))s] $state..."
                ;;
            *)
                echo "  [$((i*10))s] $state: $(echo "$status" | head -1)"
                ;;
        esac
    done

    echo "  ❌ Timeout waiting for result"
    return 1
}

poll_until_ready() {
    local endpoint_id="$1"
    echo ""
    echo "--- Waiting for worker ---"

    for i in $(seq 1 30); do
        if test_endpoint "$endpoint_id"; then
            return 0
        fi
        echo "  Retrying in ${SLEEP_BETWEEN}s... ($i/30)"
        sleep "$SLEEP_BETWEEN"
    done
    return 1
}

# ── Main loop ───────────────────────────────────────────────────────────────
ATTEMPT=0

while true; do
    ATTEMPT=$((ATTEMPT + 1))
    echo ""
    echo "========================================"
    echo " Serverless Test — Attempt $ATTEMPT"
    echo "========================================"

    # Wait for GHA to have a ready image
    if [[ "${GITHUB_TOKEN:-}" ]]; then
        wait_for_gha || true
    else
        echo "  [skip] No GITHUB_TOKEN — assuming image is ready"
        sleep 5
    fi

    # Create endpoint
    EP_ID=$(create_or_get_endpoint)
    if [[ -z "$EP_ID" ]]; then
        echo "❌ Failed to create endpoint. Retrying..."
        sleep 10
        continue
    fi

    # Test
    if poll_until_ready "$EP_ID"; then
        echo ""
        echo "========================================"
        echo " 🎉 SUCCESS on attempt $ATTEMPT!"
        echo "========================================"
        echo "  Endpoint ID: $EP_ID"
        echo "  App URL:     https://api.runpod.ai/v2/$EP_ID"
        echo "========================================"
        exit 0
    fi

    # Cleanup failed endpoint
    echo ""
    echo "--- Cleaning up failed endpoint ---"
    $RCTL serverless delete --id "$EP_ID" 2>/dev/null || true

    if [[ "$LOOP" != "true" ]]; then
        echo "❌ Failed. Use --loop to retry."
        exit 1
    fi

    if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
        echo "❌ Max attempts ($MAX_ATTEMPTS) reached."
        exit 1
    fi

    echo "  Next attempt in 10s..."
    sleep 10
done
