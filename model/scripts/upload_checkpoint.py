"""Upload fine-tuned checkpoint to W&B as a versioned artifact.

Called by the finetune-loop.sh script after training completes.
Also updates the GCS weights bucket with the latest checkpoint path.

Usage:
  uv run python scripts/upload_checkpoint.py \
    --checkpoint-dir checkpoints/moondream-20260615/best \
    --model moondream \
    --notes "Fine-tuned on 15 feedback samples"
"""

import argparse
import subprocess
from pathlib import Path

import wandb
from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Upload fine-tuned checkpoint to W&B and GCS",
    )
    parser.add_argument("--checkpoint-dir", required=True, type=Path)
    parser.add_argument(
        "--model",
        required=True,
        choices=["moondream", "phi35", "qwen2-vl"],
    )
    parser.add_argument("--notes", default="")
    parser.add_argument(
        "--gcs-bucket",
        default="ahnpolished-strg-weights",
    )
    args = parser.parse_args()

    _load_dotenv()

    ckpt = args.checkpoint_dir
    if not ckpt.exists():
        print(f"ERROR: checkpoint dir not found: {ckpt}")
        return

    artifact_name = f"{args.model}-checkpoint"

    run = wandb.init(
        entity=WANDB_ENTITY,
        project=WANDB_PROJECT,
        name=f"checkpoint-upload-{args.model}",
        job_type="model-upload",
        notes=args.notes,
        tags=["phase:checkpoint-upload", f"model:{args.model}"],
    )

    art = wandb.Artifact(
        name=artifact_name,
        type="model",
        description=f"Fine-tuned {args.model} checkpoint",
        metadata={
            "model": args.model,
            "notes": args.notes,
            "files": [f.name for f in ckpt.iterdir()][:10],
        },
    )
    art.add_dir(str(ckpt))
    run.log_artifact(art)
    run.finish()

    print(f"Uploaded {artifact_name} v{art.version} to W&B")
    print(f"  {WANDB_ENTITY}/{WANDB_PROJECT}/{artifact_name}:v{art.version}")

    # Also upload to GCS weights bucket
    gcs_path = f"gs://{args.gcs_bucket}/weights/{args.model}-lora-v{art.version}/"
    print(f"Uploading to GCS: {gcs_path}")
    subprocess.run(
        ["gsutil", "-m", "cp", "-r", f"{ckpt}/*", gcs_path],
        check=False,
    )


if __name__ == "__main__":
    main()
