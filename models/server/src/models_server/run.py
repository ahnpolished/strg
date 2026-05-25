import argparse
import json
import statistics
from pathlib import Path

import torch
import wandb

from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv
from models_server.base import ServerModelRunner

RUNNERS: dict[str, type[ServerModelRunner]] = {}

def _registry():
    from models_server.donut import DonutRunner
    from models_server.florence2 import Florence2Runner
    from models_server.internvl2 import InternVL2Runner
    from models_server.qwen2_vl import Qwen2VLRunner
    return {
        "qwen2-vl": Qwen2VLRunner,
        "internvl2": InternVL2Runner,
        "florence2": Florence2Runner,
        "donut": DonutRunner,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, choices=["qwen2-vl", "internvl2", "florence2", "donut"])
    parser.add_argument("--images", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ground-truth", type=Path, default=None)
    parser.add_argument("--phase", default="baseline")
    args = parser.parse_args()

    registry = _registry()
    runner: ServerModelRunner = registry[args.model]()

    print(f"Loading {args.model}...")
    runner.load()

    if torch.cuda.is_available():
        torch.cuda.reset_peak_memory_stats()

    output_dir = args.output / args.model
    results = runner.run_batch(args.images, output_dir)

    latencies = [r["latency_s"] for r in results]
    p50 = statistics.median(latencies) if latencies else 0.0
    p95 = sorted(latencies)[int(len(latencies) * 0.95)] if latencies else 0.0
    parse_errors = sum(r["parse_error"] for r in results)
    vram_gb = (
        torch.cuda.max_memory_allocated() / 1e9 if torch.cuda.is_available() else 0.0
    )

    summary = {
        "model": args.model,
        "phase": args.phase,
        "photos_evaluated": len(results),
        "parse_error_count": parse_errors,
        "latency_p50": p50,
        "latency_p95": p95,
        "peak_vram_gb": vram_gb,
    }
    print(json.dumps(summary, indent=2))

    if args.ground_truth:
        import subprocess
        subprocess.run([
            "python", "-m", "evaluation.run",
            "--model", args.model,
            "--predictions", str(output_dir),
            "--ground-truth", str(args.ground_truth),
            "--phase", args.phase,
        ])
    else:
        _load_dotenv()
        run = wandb.init(
            entity=WANDB_ENTITY,
            project=WANDB_PROJECT,
            name=f"{args.model}-{args.phase}",
            config=summary,
            tags=[f"phase:{args.phase}", f"model:{args.model}", "inference:server"],
        )
        run.summary.update(summary)
        run.finish()


if __name__ == "__main__":
    main()
