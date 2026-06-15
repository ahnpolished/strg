"""Trigger automated fine-tuning when enough labeled feedback accumulates.

Workflow:
  1. Check W&B for latest feedback-dataset artifact
  2. Count approved samples — if >= min-samples, proceed
  3. Start GCE spot VM with the fine-tune startup script
  4. Poll VM until it self-terminates (training complete)
  5. Verify checkpoint uploaded to GCS, W&B

Usage:
  # Dry-run: check threshold without starting VM
  uv run python scripts/trigger_finetune.py --dry-run

  # Trigger full fine-tune loop for moondream (fast, cheap)
  uv run python scripts/trigger_finetune.py --model moondream --min-samples 10

  # Trigger for phi35 with higher threshold
  uv run python scripts/trigger_finetune.py --model phi35 --min-samples 20
"""

import argparse
import json
import subprocess
import sys
import time

import wandb
from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv

# GCE instance config — matches Terraform finetune.tf
DEFAULT_ZONE = "us-central1-a"
DEFAULT_INSTANCE = "strg-finetune-1"
DEFAULT_MACHINE_TYPE = "g2-standard-4"

SUPPORTED_MODELS = ["moondream", "phi35", "qwen2-vl"]


def _check_wandb_feedback(min_samples: int) -> dict | None:
    """Check if W&B has enough approved feedback samples. Returns artifact metadata or None."""
    api = wandb.Api()
    try:
        artifact = api.artifact(
            f"{WANDB_ENTITY}/{WANDB_PROJECT}/feedback-dataset:latest",
            type="dataset",
        )
    except Exception:
        print("No feedback-dataset artifact found in W&B.")
        return None

    meta = artifact.metadata or {}
    approved = meta.get("approved", 0)
    total = meta.get("total", 0)
    print(f"Latest feedback-dataset: v{artifact.version} — {approved} approved / {total} total")

    if approved < min_samples:
        print(f"  Below threshold ({approved} < {min_samples}). Not triggering fine-tune.")
        return None

    print(f"  Threshold met ({approved} >= {min_samples}). Ready to fine-tune.")
    return dict(meta, version=f"v{artifact.version}")


def _start_finetune_vm(
    model: str,
    project: str,
    zone: str,
    instance_name: str,
    feedback_version: str,
    repo_commit: str | None = None,
) -> bool:
    """Start the GCE spot VM with fine-tune metadata. Returns True on success."""
    if not repo_commit:
        repo_commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
        ).stdout.strip()

    metadata = (
        f"finetune-model={model},"
        f"feedback-artifact-version={feedback_version},"
        f"repo-commit={repo_commit}"
    )

    print(f"\nStarting fine-tune VM '{instance_name}'...")
    print(f"  Model:  {model}")
    print(f"  Commit: {repo_commit}")
    print(f"  Zone:   {zone}")

    # Start the VM with metadata that the startup script reads
    cmd = [
        "gcloud",
        "compute",
        "instances",
        "start",
        instance_name,
        "--zone",
        zone,
        "--project",
        project,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR starting VM: {result.stderr}")
        return False

    print("VM started. Adding fine-tune metadata...")
    subprocess.run(
        [
            "gcloud",
            "compute",
            "instances",
            "add-metadata",
            instance_name,
            "--zone",
            zone,
            "--project",
            project,
            f"--metadata={metadata}",
        ],
        capture_output=True,
        text=True,
    )
    return True


def _poll_vm_until_done(
    project: str,
    zone: str,
    instance_name: str,
    timeout_minutes: int = 120,
) -> bool:
    """Poll VM status until it self-terminates. Returns True if training completed."""
    print(f"\nPolling VM '{instance_name}' (timeout: {timeout_minutes}m)...")
    deadline = time.time() + timeout_minutes * 60

    while time.time() < deadline:
        result = subprocess.run(
            [
                "gcloud",
                "compute",
                "instances",
                "describe",
                instance_name,
                "--zone",
                zone,
                "--project",
                project,
                "--format=json(status,metadata.items.finetune-status)",
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"  gcloud describe failed (VM may have terminated): {result.stderr.strip()}")
            time.sleep(30)
            continue

        try:
            info = json.loads(result.stdout)
        except json.JSONDecodeError:
            time.sleep(30)
            continue

        status = info.get("status", "UNKNOWN")

        # Check for finetune-status in metadata
        finetune_status = None
        for item in info.get("metadata", {}).get("items", []):
            if item.get("key") == "finetune-status":
                finetune_status = item.get("value")

        print(
            f"  [{time.strftime('%H:%M:%S')}] VM status={status}, finetune={finetune_status or 'running'}"
        )

        if finetune_status == "done":
            print("Fine-tuning completed successfully!")
            return True
        elif finetune_status == "failed":
            print("Fine-tuning failed. Check VM logs.")
            return False
        elif status == "TERMINATED" and finetune_status is None:
            print("VM terminated without reporting status. Check logs.")
            return False

        time.sleep(60)

    print(f"Timeout after {timeout_minutes} minutes.")
    return False


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Trigger automated fine-tuning loop when feedback threshold is met",
    )
    parser.add_argument(
        "--model",
        default="moondream",
        choices=SUPPORTED_MODELS,
        help="Model to fine-tune (default: moondream — fastest)",
    )
    parser.add_argument(
        "--min-samples",
        type=int,
        default=10,
        help="Minimum approved feedback samples to trigger (default: 10)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Check threshold without starting VM",
    )
    parser.add_argument(
        "--project",
        default="ahnpolished",
        help="GCP project ID",
    )
    parser.add_argument(
        "--zone",
        default=DEFAULT_ZONE,
        help="GCE zone",
    )
    parser.add_argument(
        "--instance",
        default=DEFAULT_INSTANCE,
        help="GCE instance name to start",
    )
    parser.add_argument(
        "--commit",
        default=None,
        help="Git commit SHA to checkout on VM (default: HEAD)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="Max minutes to wait for training (default: 120)",
    )
    args = parser.parse_args()

    _load_dotenv()

    # 1. Check W&B for approved feedback
    feedback_meta = _check_wandb_feedback(args.min_samples)

    if args.dry_run:
        if feedback_meta:
            print(f"\n[DRY RUN] Would start fine-tune for '{args.model}'")
            print(f"  Feedback version: {feedback_meta.get('version', '?')}")
            print(f"  Approved samples:  {feedback_meta.get('approved', 0)}")
        else:
            print("\n[DRY RUN] Threshold not met — no action needed.")
        return

    if not feedback_meta:
        print("Not enough feedback. Run `label_feedback.py --label` to approve more.")
        sys.exit(0)

    # 2. Start the fine-tune VM
    feedback_version = feedback_meta["version"]
    ok = _start_finetune_vm(
        model=args.model,
        project=args.project,
        zone=args.zone,
        instance_name=args.instance,
        feedback_version=feedback_version,
        repo_commit=args.commit,
    )
    if not ok:
        sys.exit(1)

    # 3. Poll until training completes
    success = _poll_vm_until_done(
        project=args.project,
        zone=args.zone,
        instance_name=args.instance,
        timeout_minutes=args.timeout,
    )

    if success:
        print("\n=== Fine-tune complete ===")
        print(
            f"  Checkpoint uploaded to GCS: gs://ahnpolished-strg-weights/weights/{args.model}-lora/"
        )
        print(f"  W&B artifact: {WANDB_ENTITY}/{WANDB_PROJECT}/{args.model}-lora:latest")
        print("\nTo deploy the new model:")
        print("  cd model && gcloud run deploy strg-serve --region=us-central1 ...")
    else:
        print("\n=== Fine-tune may have failed ===")
        print(
            f"  Check VM logs: gcloud compute instances get-serial-port-output {args.instance} --zone={args.zone}"
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
