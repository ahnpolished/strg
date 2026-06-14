#!/bin/bash
# ── Create billing budget via gcloud (Terraform cannot with user ADC) ──
#
# The billingbudgets API rejects user ADC even with user_project_override
# set on the Terraform provider. This script creates the same budget
# via gcloud CLI which handles the quota project header correctly.
#
# Prerequisites:
#   1. terraform apply completed (budget.tf is now a no-op)
#   2. gcloud auth application-default set-quota-project ahnpolished
#
# Usage:
#   bash scripts/setup-budget.sh

set -euo pipefail

PROJECT="${GCP_PROJECT:-ahnpolished}"
BILLING_ACCOUNT="0191F1-84F4EC-45730A"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-10}"
EMAIL="${BUDGET_EMAIL:-stahn1995@gmail.com}"
DISPLAY_NAME="strg-gpu-serving"

# Get project number
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')

# Create the notification channel
echo "Creating email notification channel for $EMAIL ..."
CHANNEL_ID=$(gcloud beta monitoring channels create \
  --project="$PROJECT" \
  --display-name="strg-budget-alerts" \
  --type=email \
  --channel-labels="email_address=$EMAIL" \
  --format='value(name)')

echo "  Channel: $CHANNEL_ID"

# Create the billing budget with thresholds at 50%, 80%, 100%
echo "Creating billing budget: $DISPLAY_NAME (\$${BUDGET_AMOUNT}/month) ..."
gcloud billing budgets create \
  --billing-account="$BILLING_ACCOUNT" \
  --display-name="$DISPLAY_NAME" \
  --budget-amount="${BUDGET_AMOUNT}USD" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.8 \
  --threshold-rule=percent=1.0 \
  --all-updates-rule-monitoring-notification-channels="$CHANNEL_ID" \
  --filter-projects="projects/$PROJECT_NUMBER" \
  --filter-credit-types-treatment=exclude-all-credits

echo ""
echo "=== Done ==="
echo "Budget '$DISPLAY_NAME' created."
echo "Alerts will fire at: 50% (\$$(( BUDGET_AMOUNT / 2 ))), 80% (\$$(( BUDGET_AMOUNT * 4 / 5 ))), 100% (\$${BUDGET_AMOUNT})"
echo "Notifications go to: $EMAIL"
echo ""
echo "View in console: https://console.cloud.google.com/billing/$BILLING_ACCOUNT/budgets?project=$PROJECT"
