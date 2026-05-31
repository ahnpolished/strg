"""Upload fine-tuned LoRA checkpoint to W&B and save local copy.

Usage:
  uv run python scripts/upload_checkpoint.py \
    --checkpoint-dir infra/runpod/logs/checkpoints/<run-id>/qwen2-vl \
    --model qwen2-vl

Uploads to W&B as artifact and saves a stable local copy.
"""

import argparse
import shutil
from pathlib import Path

from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT
from models_server.prompt import EXTRACTION_PROMPT

import wandb


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--checkpoint-dir",
        required=True,
        type=Path,
        help="Path to the LoRA checkpoint (adapter_model.safetensors, adapter_config.json, etc.)",
    )
    parser.add_argument(
        "--model",
        default="qwen2-vl",
        choices=["qwen2-vl"],
        help="Model name for artifact naming",
    )
    parser.add_argument(
        "--local-copy",
        type=Path,
        default=None,
        help="Optional: save a local copy to this directory (for serving without W&B)",
    )
    parser.add_argument(
        "--epochs",
        type=int,
        default=3,
        help="Training epochs (for artifact metadata)",
    )
    parser.add_argument(
        "--notes",
        default="QLoRA fine-tuned Qwen2-VL-7B for workout extraction",
        help="Artifact description",
    )
    args = parser.parse_args()

    ckpt_dir: Path = args.checkpoint_dir
    if not ckpt_dir.exists():
        print(f"ERROR: checkpoint directory not found: {ckpt_dir}")
        print("Run fine-tuning first, then check infra/runpod/logs/checkpoints/")
        exit(1)

    # Verify we have the right files
    required = ["adapter_config.json", "adapter_model.safetensors"]
    for f in required:
        if not (ckpt_dir / f).exists():
            print(f"ERROR: missing {f} in {ckpt_dir}")
            print("Contents:", [p.name for p in ckpt_dir.iterdir()])
            exit(1)

    print(f"Found checkpoint at {ckpt_dir}")
    print(f"  Files: {[p.name for p in ckpt_dir.iterdir()]}")

    # Save local copy if requested
    if args.local_copy:
        local_path = Path(args.local_copy)
        local_path.mkdir(parents=True, exist_ok=True)
        for f in ckpt_dir.iterdir():
            if f.is_file():
                shutil.copy2(f, local_path / f.name)
        print(f"Local copy saved to {local_path}")

    # Upload to W&B
    run = wandb.init(
        entity=WANDB_ENTITY,
        project=WANDB_PROJECT,
        name=f"{args.model}-checkpoint-upload",
        job_type="upload-checkpoint",
        config={
            "model": args.model,
            "epochs": args.epochs,
            "base_model": "Qwen/Qwen2-VL-7B-Instruct",
        },
        tags=["phase:checkpoint-upload", f"model:{args.model}"],
    )

    artifact = wandb.Artifact(
        name=f"{args.model}-lora",
        type="model",
        description=args.notes,
        metadata={
            "base_model": "Qwen/Qwen2-VL-7B-Instruct",
            "framework": "peft",
            "format": "safetensors",
            "epochs": args.epochs,
            "extraction_prompt": EXTRACTION_PROMPT[:200],
        },
    )
    artifact.add_dir(str(ckpt_dir))
    run.log_artifact(artifact)
    run.finish()

    print("\nCheckpoint uploaded to W&B!")
    print(f"  Artifact: {args.model}-lora (v{artifact.version})")
    print(f"  Project: {WANDB_ENTITY}/{WANDB_PROJECT}")
    print(f"  Local copy: {args.local_copy or 'not saved'}")
    print("\nTo serve with this checkpoint:")
    print(f"  export STRG_QWEN_LORA_CHECKPOINT={args.local_copy or ckpt_dir}")
    print("  uv run python -m models_server.serve")


if __name__ == "__main__":
    main()
