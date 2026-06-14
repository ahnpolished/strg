#!/bin/bash
# ── Push WIF credentials to GitHub Actions secrets ───────────────────
#
# Reads Terraform outputs from model/infra/gcp/ and sets the two
# required GitHub Actions secrets via the gh CLI.
#
# Prerequisites:
#   1. terraform apply has completed successfully
#   2. gh CLI is installed and authenticated (gh auth login)
#   3. You have admin access to the target repository
#
# Usage:
#   bash scripts/gh-set-secrets.sh [org/repo]
#
# If org/repo is omitted, auto-detects from the current git remote.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO="${1:-}"
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  if [ -z "$REPO" ]; then
    echo "ERROR: Could not auto-detect repo. Pass it explicitly:"
    echo "  bash scripts/gh-set-secrets.sh myorg/myrepo"
    exit 1
  fi
fi

echo "=== Push WIF secrets to GitHub Actions ==="
echo "Repository: $REPO"
echo ""

# ── Read Terraform outputs ──────────────────────────────────────────
echo "[1/4] Reading Terraform outputs..."
GCP_WIF_PROVIDER=$(terraform -chdir="$TF_DIR" output -raw wif_provider_name)
GCP_WIF_SA=$(terraform -chdir="$TF_DIR" output -raw github_actions_sa_email)
GCP_PROJECT=$(terraform -chdir="$TF_DIR" output -raw project || echo "ahnpolished")

echo "  WIF Provider: $GCP_WIF_PROVIDER"
echo "  SA Email:     $GCP_WIF_SA"
echo "  Project:      $GCP_PROJECT"
echo ""

# ── Set GitHub Actions secrets + variables ──────────────────────────
echo "[2/4] Setting GCP_WIF_PROVIDER..."
gh secret set GCP_WIF_PROVIDER \
  --body "$GCP_WIF_PROVIDER" \
  --repo "$REPO"

echo "[3/4] Setting GCP_WIF_SA..."
gh secret set GCP_WIF_SA \
  --body "$GCP_WIF_SA" \
  --repo "$REPO"

echo "[4/4] Setting GCP_PROJECT variable..."
gh variable set GCP_PROJECT \
  --body "$GCP_PROJECT" \
  --repo "$REPO"

# ── Verify ──────────────────────────────────────────────────────────
echo ""
echo "=== Done ==="
echo "Secrets + variable set for $REPO:"
echo "  GCP_WIF_PROVIDER  (hidden)"
echo "  GCP_WIF_SA        (hidden)"
echo "  GCP_PROJECT       = $GCP_PROJECT"
echo ""
echo "Verify with:"
echo "  gh secret list --repo $REPO"
echo "  gh variable list --repo $REPO"
echo ""
echo "Now push to main or run the workflow manually to test the full cycle."
