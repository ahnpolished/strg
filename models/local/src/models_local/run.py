import argparse
import json
import statistics
import tracemalloc
from pathlib import Path

import wandb
from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv

from models_local.base import LocalModelRunner


def _get_runner_class(model_name: str):
    if model_name == "moondream":
        from models_local.moondream import MoondreamRunner

        return MoondreamRunner
    elif model_name == "smolvlm":
        from models_local.smolvlm import SmolVLMRunner

        return SmolVLMRunner
    elif model_name == "minicpm":
        from models_local.minicpm import MiniCPMRunner

        return MiniCPMRunner
    elif model_name == "phi35":
        from models_local.phi35 import Phi35VisionRunner

        return Phi35VisionRunner
    else:
        raise ValueError(f"Unknown model: {model_name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--model", required=True, choices=["moondream", "smolvlm", "minicpm", "phi35"]
    )
    parser.add_argument("--images", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ground-truth", type=Path, default=None)
    parser.add_argument("--phase", default="baseline")
    args = parser.parse_args()

    runner: LocalModelRunner = _get_runner_class(args.model)()

    tracemalloc.start()
    print(f"Loading {args.model}...")
    runner.load()

    output_dir = args.output / args.model
    results = runner.run_batch(args.images, output_dir)

    _, peak_bytes = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    latencies = [r["latency_s"] for r in results]
    p50 = statistics.median(latencies) if latencies else 0.0
    p95 = sorted(latencies)[int(len(latencies) * 0.95)] if latencies else 0.0
    parse_errors = sum(r["parse_error"] for r in results)

    summary = {
        "model": args.model,
        "phase": args.phase,
        "photos_evaluated": len(results),
        "parse_error_count": parse_errors,
        "latency_p50": p50,
        "latency_p95": p95,
        "peak_ram_gb": peak_bytes / 1e9,
    }
    print(json.dumps(summary, indent=2))

    if args.ground_truth:
        import subprocess

        subprocess.run(
            [
                "python",
                "-m",
                "evaluation.run",
                "--model",
                args.model,
                "--predictions",
                str(output_dir),
                "--ground-truth",
                str(args.ground_truth),
                "--phase",
                args.phase,
            ]
        )
    else:
        _load_dotenv()
        run = wandb.init(
            entity=WANDB_ENTITY,
            project=WANDB_PROJECT,
            name=f"{args.model}-{args.phase}",
            config=summary,
            tags=[f"phase:{args.phase}", f"model:{args.model}", "inference:local"],
        )
        run.summary.update(summary)
        run.finish()


if __name__ == "__main__":
    main()
