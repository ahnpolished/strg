"""
Training data collection and augmentation pipeline (HUM-1299).

Usage:
  # Add a real photo + annotation interactively
  uv run python data/collect_training.py add --image path/to/photo.jpg

  # Augment existing training images to reach target volume
  uv run python data/collect_training.py augment --target 200

  # Show dataset stats
  uv run python data/collect_training.py stats

  # Version current dataset as W&B artifact
  uv run python data/collect_training.py push --version v1
"""
import json
import shutil
import sys
from pathlib import Path

TRAIN_DIR = Path("data/train")
TEST_DIR = Path("data/test")


# ---------------------------------------------------------------------------
# add
# ---------------------------------------------------------------------------

def cmd_add(image_path: Path) -> None:
    TRAIN_DIR.mkdir(parents=True, exist_ok=True)
    existing = sorted(TRAIN_DIR.glob("*.jpg")) + sorted(TRAIN_DIR.glob("*.jpeg"))
    idx = len(existing) + 1
    dest_img = TRAIN_DIR / f"{idx:04d}.jpg"
    dest_json = TRAIN_DIR / f"{idx:04d}.json"

    shutil.copy(image_path, dest_img)
    print(f"Copied image → {dest_img}")
    print("Enter workout entries (empty exercise to finish):")

    import datetime
    from common.schema import WorkoutEntry, WorkoutPage, dump_page

    date_str = input("  Date (YYYY-MM-DD): ").strip()
    try:
        date = datetime.date.fromisoformat(date_str)
    except ValueError:
        print("Invalid date, using today")
        date = datetime.date.today()

    entries = []
    while True:
        exercise = input("  Exercise (empty to finish): ").strip()
        if not exercise:
            break
        sets_s = input("    Sets (enter to skip): ").strip()
        reps_s = input("    Reps (enter to skip): ").strip()
        kg_s = input("    Weight kg (enter to skip): ").strip()
        notes = input("    Notes (enter to skip): ").strip() or None
        entries.append(WorkoutEntry(
            date=date,
            exercise=exercise,
            sets=int(sets_s) if sets_s else None,
            reps=int(reps_s) if reps_s else None,
            weight_kg=float(kg_s) if kg_s else None,
            notes=notes,
        ))

    page = WorkoutPage(entries=entries)
    dump_page(page, dest_json)
    print(f"Saved {len(entries)} entries → {dest_json}")


# ---------------------------------------------------------------------------
# augment
# ---------------------------------------------------------------------------

def cmd_augment(target: int) -> None:
    try:
        import albumentations as A
        import numpy as np
        from PIL import Image as PILImage
    except ImportError:
        print("Install albumentations: uv add albumentations --package models-server")
        sys.exit(1)

    sources = sorted(TRAIN_DIR.glob("*.jpg")) + sorted(TRAIN_DIR.glob("*.jpeg"))
    # Exclude test set images
    test_stems = {p.stem for p in TEST_DIR.glob("*.jpg")}
    sources = [p for p in sources if p.stem not in test_stems]

    current_count = len(sources)
    if current_count >= target:
        print(f"Already have {current_count} training images (target={target}), nothing to do")
        return

    transform = A.Compose([
        A.Rotate(limit=5, p=0.5),
        A.RandomBrightnessContrast(brightness_limit=0.15, contrast_limit=0.15, p=0.7),
        A.GaussNoise(var_limit=(5, 25), p=0.5),
        A.Perspective(scale=(0.02, 0.05), p=0.4),
        A.Sharpen(alpha=(0.1, 0.3), p=0.3),
    ])

    needed = target - current_count
    aug_dir = TRAIN_DIR / "aug"
    aug_dir.mkdir(exist_ok=True)

    import random
    aug_idx = 0
    while aug_idx < needed:
        src = random.choice(sources)
        img = np.array(PILImage.open(src).convert("RGB"))
        augmented = transform(image=img)["image"]
        out_path = aug_dir / f"aug_{aug_idx:04d}.jpg"
        PILImage.fromarray(augmented).save(out_path, "JPEG", quality=85)
        # Copy ground truth JSON
        json_src = src.with_suffix(".json")
        if json_src.exists():
            shutil.copy(json_src, aug_dir / f"aug_{aug_idx:04d}.json")
        aug_idx += 1

    print(f"Generated {needed} augmented images in {aug_dir}/")
    print(f"Total training samples: {current_count + needed}")


# ---------------------------------------------------------------------------
# stats
# ---------------------------------------------------------------------------

def cmd_stats() -> None:
    from common.schema import load_page

    imgs = sorted(TRAIN_DIR.glob("**/*.jpg"))
    jsons = sorted(TRAIN_DIR.glob("**/*.json"))
    print(f"Training images:    {len(imgs)}")
    print(f"Ground truth files: {len(jsons)}")

    field_null_counts: dict[str, int] = {f: 0 for f in ["sets", "reps", "weight_kg", "notes"]}
    total_entries = 0
    for j in jsons:
        try:
            page = load_page(j)
            for entry in page.entries:
                total_entries += 1
                for field in field_null_counts:
                    if getattr(entry, field) is None:
                        field_null_counts[field] += 1
        except Exception:
            pass

    print(f"Total entries:      {total_entries}")
    if total_entries:
        print("Null rates by field:")
        for field, count in field_null_counts.items():
            print(f"  {field:<12}: {count/total_entries:.1%}")


# ---------------------------------------------------------------------------
# push (W&B artifact)
# ---------------------------------------------------------------------------

def cmd_push(version: str) -> None:
    import wandb
    from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv
    _load_dotenv()

    run = wandb.init(entity=WANDB_ENTITY, project=WANDB_PROJECT, job_type="dataset")
    artifact = wandb.Artifact(name="train-dataset", type="dataset", metadata={"version": version})
    artifact.add_dir(str(TRAIN_DIR))
    run.log_artifact(artifact)
    run.finish()
    print(f"Pushed {TRAIN_DIR} as W&B artifact train-dataset:{version}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd")

    p_add = sub.add_parser("add")
    p_add.add_argument("--image", required=True, type=Path)

    p_aug = sub.add_parser("augment")
    p_aug.add_argument("--target", type=int, default=200)

    sub.add_parser("stats")

    p_push = sub.add_parser("push")
    p_push.add_argument("--version", default="v1")

    args = parser.parse_args()
    if args.cmd == "add":
        cmd_add(args.image)
    elif args.cmd == "augment":
        cmd_augment(args.target)
    elif args.cmd == "stats":
        cmd_stats()
    elif args.cmd == "push":
        cmd_push(args.version)
    else:
        parser.print_help()
