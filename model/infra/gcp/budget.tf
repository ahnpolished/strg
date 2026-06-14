# ── Billing budget — create MANUALLY via gcloud ─────────────────────
#
# The billingbudgets.googleapis.com API rejects user ADC even with
# user_project_override. Terraform simply cannot create this resource
# with your current credentials.
#
# Run this ONCE after terraform apply:
#
#   bash scripts/setup-budget.sh
#
# It creates: $10 budget, alerts at $5/$8/$10, emails stahn1995@gmail.com.
#
# If you switch to a service account for Terraform (recommended for
# production), uncomment the resources below and they'll work.

# resource "google_monitoring_notification_channel" "budget_email" {
#   display_name = "strg-budget-alerts"
#   project      = var.project
#   type         = "email"
#   labels = {
#     email_address = var.budget_email
#   }
# }
#
# resource "google_billing_budget" "gpu_serving" {
#   billing_account = "0191F1-84F4EC-45730A"
#   display_name    = "strg-gpu-serving"
#   amount {
#     specified_amount {
#       currency_code = "USD"
#       units         = tostring(var.budget_amount)
#     }
#   }
#   dynamic "threshold_rules" {
#     for_each = var.budget_alert_thresholds
#     content {
#       threshold_percent = threshold_rules.value
#       spend_basis       = "CURRENT_SPEND"
#     }
#   }
#   all_updates_rule {
#     monitoring_notification_channels = [google_monitoring_notification_channel.budget_email.id]
#   }
#   budget_filter {
#     projects               = ["projects/${data.google_project.current.number}"]
#     credit_types_treatment = "EXCLUDE_ALL_CREDITS"
#     services               = ["all"]
#   }
# }
#
# data "google_project" "current" {
#   project_id = var.project
# }
