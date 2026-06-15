"""Pull feedback from GCS, create W&B tables for labeling/review.

Workflow:
  1. Pull all photo+json pairs from gs://{BUCKET}/feedback/
  2. Build a W&B Table: photo, predicted, corrected, model, submitted_at, status
  3. Log as W&B artifact 'feedback-dataset' for downstream fine-tuning
  4. With --label: mark reviewed entries as approved/rejected via CLI prompt
  5. Sync review status back to GCS as a manifest

Usage:
  # Pull feedback and log to W&B (dry review):
  uv run python scripts/label_feedback.py --bucket ahnpolished-strg-feedback

  # Interactive labeling session:
  uv run python scripts/label_feedback.py --bucket ... --label

  # Only approved entries, minimum 5:
  uv run python scripts/label_feedback.py --bucket ... --min-approved 5
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import wandb
from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv

MANIFEST_FILE = "feedback_manifest.json"
TABLE_COLUMNS = [
    "feedback_id",
    "photo",
    "predicted_entries",
    "corrected_entries",
    "model",
    "submitted_at",
    "notes",
    "review_status",
]


def pull_feedback_from_gcs(bucket: str, work_dir: Path) -> list[dict]:
    """Download all feedback pairs from GCS and parse into a list of records."""
    if not bucket:
        print("ERROR: No GCS bucket specified. Use --bucket")
        sys.exit(1)

    gs_path = f"gs://{bucket}/feedback/"
    local_feedback = work_dir / "feedback"
    local_feedback.mkdir(parents=True, exist_ok=True)

    print(f"Pulling feedback from {gs_path} ...")
    result = subprocess.run(
        ["gsutil", "-m", "cp", "-r", gs_path, str(local_feedback)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 and "No such object" not in result.stderr:
        print(f"gsutil warning: {result.stderr.strip()}")

    records = []
    for subdir in sorted(local_feedback.iterdir()):
        if not subdir.is_dir():
            continue
        jpg = subdir / f"{subdir.name}.jpg"
        json_path = subdir / f"{subdir.name}.json"
        if not jpg.exists() or not json_path.exists():
            print(f"  Skipping incomplete {subdir.name}")
            continue
        try:
            meta = json.loads(json_path.read_text())
        except json.JSONDecodeError:
            print(f"  Skipping corrupt JSON: {json_path}")
            continue
        records.append(
            {
                "feedback_id": subdir.name,
                "photo_path": str(jpg),
                "predicted_entries": meta.get("original_entries") or meta.get("entries", []),
                "corrected_entries": meta["entries"],
                "model": meta.get("model", "unknown"),
                "submitted_at": meta.get("submitted_at", ""),
                "notes": meta.get("notes", ""),
                "review_status": "new",
            }
        )
    print(f"  Found {len(records)} feedback submissions")
    return records


def _load_manifest(work_dir: Path) -> dict[str, str]:
    """Load existing review status from manifest."""
    manifest_path = work_dir / MANIFEST_FILE
    if manifest_path.exists():
        return json.loads(manifest_path.read_text())
    return {}


def _save_manifest(work_dir: Path, status_map: dict[str, str]) -> None:
    (work_dir / MANIFEST_FILE).write_text(json.dumps(status_map, indent=2))


def interactive_label(records: list[dict], work_dir: Path) -> list[dict]:
    """Interactive CLI to review and approve/reject feedback entries."""
    status_map = _load_manifest(work_dir)

    print("\n" + "=" * 60)
    print(f"Interactive labeling — {len(records)} submissions to review")
    print("  [a] approve   [r] reject   [s] skip   [q] quit")
    print("=" * 60)

    for i, rec in enumerate(records):
        fid = rec["feedback_id"]
        if fid in status_map:
            rec["review_status"] = status_map[fid]
            continue

        print(f"\n--- [{i + 1}/{len(records)}] {fid} ---")
        print(f"  Model: {rec['model']}")
        print(f"  Submitted: {rec['submitted_at']}")
        print(f"  Notes: {rec['notes']}")
        print(f"  Predicted: {json.dumps(rec['predicted_entries'], indent=2)}")
        print(f"  Corrected: {json.dumps(rec['corrected_entries'], indent=2)}")
        print(f"  Photo: {rec['photo_path']}")

        while True:
            choice = input("  [a/r/s/q]: ").strip().lower()
            if choice == "a":
                rec["review_status"] = "approved"
                status_map[fid] = "approved"
                break
            elif choice == "r":
                rec["review_status"] = "rejected"
                status_map[fid] = "rejected"
                break
            elif choice == "s":
                rec["review_status"] = "skipped"
                break
            elif choice == "q":
                print("  Quitting. Progress saved.")
                _save_manifest(work_dir, status_map)
                return records
            else:
                print("  Invalid. Choose a/r/s/q.")

    _save_manifest(work_dir, status_map)
    return records


def log_to_wandb(records: list[dict], only_approved: bool = False) -> str:
    """Build W&B Table and log as artifact. Returns artifact version string."""
    run = wandb.init(
        entity=WANDB_ENTITY,
        project=WANDB_PROJECT,
        name="label-feedback",
        job_type="data-labeling",
        tags=["phase:data-labeling", "feedback"],
    )

    if only_approved:
        records = [r for r in records if r["review_status"] == "approved"]
        print(f"Filtering to approved only: {len(records)} records")

    rows = []
    for rec in records:
        photo = wandb.Image(rec["photo_path"]) if Path(rec["photo_path"]).exists() else None
        rows.append(
            [
                rec["feedback_id"],
                photo,
                json.dumps(rec["predicted_entries"]),
                json.dumps(rec["corrected_entries"]),
                rec["model"],
                rec["submitted_at"],
                rec["notes"],
                rec["review_status"],
            ]
        )

    table = wandb.Table(columns=TABLE_COLUMNS, data=rows)
    run.log({"feedback/review_table": table})

    artifact = wandb.Artifact(
        name="feedback-dataset",
        type="dataset",
        description=f"Feedback submissions labeled on {datetime.utcnow().isoformat()}",
        metadata={
            "total": len(records),
            "approved": sum(1 for r in records if r["review_status"] == "approved"),
            "rejected": sum(1 for r in records if r["review_status"] == "rejected"),
            "new": sum(1 for r in records if r["review_status"] == "new"),
        },
    )
    artifact.add(table, "feedback")
    run.log_artifact(artifact)
    run.finish()

    version = f"v{artifact.version}"
    print(f"\nLogged feedback-dataset {version} to W&B")
    print(f"  {artifact.metadata}")
    return version


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pull feedback from GCS and log as W&B labeling table",
    )
    parser.add_argument(
        "--bucket",
        default="ahnpolished-strg-feedback",
        help="GCS bucket for feedback (default: ahnpolished-strg-feedback)",
    )
    parser.add_argument(
        "--label",
        action="store_true",
        help="Run interactive labeling session to approve/reject entries",
    )
    parser.add_argument(
        "--only-approved",
        action="store_true",
        help="Log only approved entries to W&B (for training)",
    )
    parser.add_argument(
        "--min-approved",
        type=int,
        default=0,
        help="Minimum approved entries required to log artifact",
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=Path("data/labeling_work"),
        help="Working directory for downloaded feedback",
    )
    args = parser.parse_args()

    _load_dotenv()
    args.work_dir.mkdir(parents=True, exist_ok=True)

    # 1. Pull from GCS
    records = pull_feedback_from_gcs(args.bucket, args.work_dir)
    if not records:
        print("No feedback submissions found. Exiting.")
        sys.exit(0)

    # 2. Interactive labeling (optional)
    if args.label:
        records = interactive_label(records, args.work_dir)

    # 3. Check minimum approved threshold
    approved = sum(1 for r in records if r["review_status"] == "approved")
    if args.min_approved and approved < args.min_approved:
        print(
            f"Insufficient approved entries: {approved} < {args.min_approved}. "
            "Run with --label to approve more."
        )
        sys.exit(1)

    # 4. Log to W&B
    version = log_to_wandb(records, only_approved=args.only_approved)

    # 5. Sync manifest back to GCS
    manifest_path = args.work_dir / MANIFEST_FILE
    if manifest_path.exists():
        gs_manifest = f"gs://{args.bucket}/feedback/{MANIFEST_FILE}"
        subprocess.run(["gsutil", "cp", str(manifest_path), gs_manifest], check=False)
        print(f"Synced manifest to {gs_manifest}")

    # 6. Summary
    print("\n=== Summary ===")
    print(f"  Total feedback:     {len(records)}")
    print(f"  Approved:           {approved}")
    print(f"  Rejected:           {sum(1 for r in records if r['review_status'] == 'rejected')}")
    print(f"  W&B artifact:       {WANDB_ENTITY}/{WANDB_PROJECT}/feedback-dataset:{version}")


if __name__ == "__main__":
    main()
