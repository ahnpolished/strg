import argparse
import json
import time
from pathlib import Path

from common.schema import load_page
from common.wandb_utils import init_run, log_prediction_table

from evaluation.metrics import FIELDS, evaluate_pages


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--predictions", required=True, type=Path)
    parser.add_argument("--ground-truth", required=True, type=Path)
    parser.add_argument("--phase", default="baseline")
    args = parser.parse_args()

    pred_dir = Path(args.predictions)
    gt_dir = Path(args.ground_truth)

    gt_files = sorted(gt_dir.glob("*.json"))
    if not gt_files:
        raise SystemExit(f"No ground truth JSON files found in {gt_dir}")

    all_rows: list[dict] = []
    per_field_matches: dict[str, list[bool]] = {f: [] for f in FIELDS}
    all_cer: list[float] = []
    latencies: list[float] = []

    for gt_path in gt_files:
        photo_id = gt_path.stem
        pred_path = pred_dir / gt_path.name
        if not pred_path.exists():
            print(f"[WARN] No prediction found for {photo_id}, skipping")
            continue

        t0 = time.perf_counter()
        predicted = load_page(pred_path)
        reference = load_page(gt_path)
        latencies.append(time.perf_counter() - t0)

        result = evaluate_pages(photo_id, predicted, reference)
        all_rows.extend(result["rows"])
        all_cer.append(result["avg_cer"])
        for f in FIELDS:
            per_field_matches[f].extend([r["match"] for r in result["rows"] if r["field"] == f])

    avg_cer = sum(all_cer) / len(all_cer) if all_cer else 0.0
    field_accuracy = {f: sum(v) / len(v) if v else 0.0 for f, v in per_field_matches.items()}
    macro_accuracy = sum(field_accuracy.values()) / len(FIELDS)
    p50_lat = sorted(latencies)[len(latencies) // 2] if latencies else 0.0
    p95_lat = sorted(latencies)[int(len(latencies) * 0.95)] if latencies else 0.0

    summary = {
        "avg_cer": avg_cer,
        "macro_field_accuracy": macro_accuracy,
        "field_accuracy": field_accuracy,
        "latency_p50": p50_lat,
        "latency_p95": p95_lat,
        "evaluated_photos": len(all_cer),
    }

    print(json.dumps(summary, indent=2))

    run = init_run(model_name=args.model, phase=args.phase, config=summary)
    log_prediction_table(run, all_rows)
    run.summary.update(summary)
    run.finish()


if __name__ == "__main__":
    main()
