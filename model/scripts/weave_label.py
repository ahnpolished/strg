"""Upload feedback photos to W&B Weave as annotatable traces.

Creates a Weave trace for each feedback submission with:
- Input: the photo (logged as media)
- Output: the model's prediction + user's correction
- Metadata: model name, timestamp, feedback_id

After running, visit the W&B Weave UI to:
1. Filter traces by tag "feedback-review"
2. Create an annotation queue with fields like "exercise_correct", etc.
3. Add these traces to the queue
4. Review in the annotation UI at wandb.ai

Usage:
  uv run python scripts/weave_label.py
  uv run python scripts/weave_label.py --limit 5
  uv run python scripts/weave_label.py --dry-run
"""

import argparse
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Annotated

import weave
from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv
from weave import Content

WEAVE_PROJECT = f"{WANDB_ENTITY}/{WANDB_PROJECT}"


@weave.op
def review_workout_photo(
    photo_path: Annotated[str, Content],
) -> dict:
    """Op that displays the photo for annotation.

    The photo is logged as media so annotators can view it in the Weave UI.
    The output contains both the model prediction and user correction for
    annotators to compare.
    """
    import json

    # Return metadata from the JSON sidecar
    json_path = Path(photo_path).with_suffix(".json")
    if json_path.exists():
        data = json.loads(json_path.read_text())
        # Add feedback to this call so annotators can see prediction vs correction
        call = weave.require_current_call()
        call.feedback.add(
            "prediction",
            {
                "model": data.get("model", "unknown"),
                "predicted_entries": data.get("original_entries", []),
                "corrected_entries": data.get("entries", []),
                "submitted_at": data.get("submitted_at", ""),
                "notes": data.get("notes", ""),
            },
        )
        return {
            "feedback_id": Path(photo_path).parent.name,
            "model": data.get("model", "?"),
            "entry_count": len(data.get("entries", [])),
            "submitted_at": data.get("submitted_at", ""),
        }
    return {"error": "no metadata found"}


def pull_feedback_from_gcs(bucket: str, work_dir: Path) -> list[dict]:
    """Download all feedback submissions from GCS."""
    gs_path = f"gs://{bucket}/feedback/*"
    local_fb = work_dir / "feedback"
    local_fb.mkdir(parents=True, exist_ok=True)

    print(f"Pulling feedback from {gs_path} ...")
    subprocess.run(
        ["gsutil", "-m", "cp", "-r", gs_path, str(local_fb) + "/"],
        capture_output=True,
        text=True,
    )

    records = []
    for subdir in sorted(local_fb.iterdir()):
        if not subdir.is_dir():
            continue
        jpg = subdir / f"{subdir.name}.jpg"
        js = subdir / f"{subdir.name}.json"
        if not jpg.exists() or not js.exists():
            continue
        try:
            meta = json.loads(js.read_text())
        except json.JSONDecodeError:
            continue
        records.append(
            {
                "feedback_id": subdir.name,
                "photo_path": str(jpg),
                "meta": meta,
            }
        )
    print(f"  Found {len(records)} submissions")
    return records


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Upload feedback photos to W&B Weave for annotation",
    )
    parser.add_argument(
        "--bucket",
        default="ahnpolished-strg-feedback",
        help="GCS feedback bucket",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Max photos to upload (0 = all)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be uploaded without sending to W&B",
    )
    args = parser.parse_args()

    _load_dotenv()

    # Pull feedback from GCS
    with tempfile.TemporaryDirectory() as tmpdir:
        work_dir = Path(tmpdir)
        records = pull_feedback_from_gcs(args.bucket, work_dir)

        if args.limit > 0:
            records = records[: args.limit]

        if not records:
            print("No feedback submissions found.")
            return

        if args.dry_run:
            print("\n=== DRY RUN — would upload to Weave ===")
            for r in records:
                meta = r["meta"]
                print(f"\n  {r['feedback_id']}")
                print(f"    Model: {meta.get('model', '?')}")
                print(f"    Entries: {len(meta.get('entries', []))}")
                print(f"    Photo: {r['photo_path']}")
            print(f"\n  Total: {len(records)} photos")
            print("\n  After uploading, visit:")
            print(f"  https://wandb.ai/{WEAVE_PROJECT}/weave/traces")
            print("  Filter by tag: feedback-review")
            return

        # Upload to Weave
        print(f"\nInitializing Weave: {WEAVE_PROJECT}")
        weave.init(WEAVE_PROJECT)

        for i, r in enumerate(records):
            meta = r["meta"]
            print(f"\n[{i + 1}/{len(records)}] {r['feedback_id']}")

            # Run the op — it logs the photo as media + adds feedback
            review_workout_photo(r["photo_path"])

            print("  ✓ Logged to Weave")

        print(f"\n{'=' * 60}")
        print(f"  Uploaded {len(records)} photos to Weave")
        print("\n  Next steps:")
        print(f"  1. Visit: https://wandb.ai/{WEAVE_PROJECT}/weave/traces")
        print("  2. Filter by tag: feedback-review")
        print("  3. Select traces → Add to annotation queue")
        print("  4. Define fields: correctness (bool), notes (string)")
        print("  5. Review and submit annotations")
        print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
