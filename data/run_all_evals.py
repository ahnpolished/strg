"""Run evaluation harness for all models and print comparison table."""

import json
from pathlib import Path

from common.schema import load_page

from evaluation.metrics import FIELDS, evaluate_pages

GT_DIR = Path("data/test")
PRED_BASE = Path("data/predictions")

MODELS = {
    "server": ["qwen2-vl", "internvl2", "florence2", "donut"],
    "local": ["moondream", "smolvlm", "minicpm", "phi35"],
}


def evaluate_model(model_name: str, pred_dir: Path) -> dict:
    all_cer, per_field = [], {f: [] for f in FIELDS}
    parse_errors = 0

    for gt_path in sorted(GT_DIR.glob("*.json")):
        pred_path = pred_dir / gt_path.name
        if not pred_path.exists():
            continue
        reference = load_page(gt_path)
        predicted = load_page(pred_path)

        if not predicted.entries:
            parse_errors += 1
            continue

        result = evaluate_pages(gt_path.stem, predicted, reference)
        all_cer.append(result["avg_cer"])
        for f in FIELDS:
            per_field[f].extend([r["match"] for r in result["rows"] if r["field"] == f])

    n = len(all_cer)
    avg_cer = sum(all_cer) / n if n else 1.0
    field_acc = {f: sum(v) / len(v) if v else 0.0 for f, v in per_field.items()}
    macro = sum(field_acc.values()) / len(FIELDS)

    return {
        "model": model_name,
        "avg_cer": round(avg_cer, 4),
        "macro_field_acc": round(macro, 4),
        "parse_errors": parse_errors,
        **{f"acc_{f}": round(field_acc[f], 3) for f in FIELDS},
    }


if __name__ == "__main__":
    results = {}
    for inference_type, model_list in MODELS.items():
        for model_name in model_list:
            pred_dir = PRED_BASE / inference_type / model_name
            r = evaluate_model(model_name, pred_dir)
            results[f"{inference_type}/{model_name}"] = r

    # Print comparison table
    header = f"{'Model':<22} {'CER':>6} {'FieldAcc':>9} {'ParseErr':>9}"
    print(header)
    print("-" * len(header))
    for key, r in results.items():
        print(f"{key:<22} {r['avg_cer']:>6.4f} {r['macro_field_acc']:>9.4f} {r['parse_errors']:>9}")

    out = Path("data/eval_results.json")
    out.write_text(json.dumps(results, indent=2))
    print(f"\nFull results written to {out}")
