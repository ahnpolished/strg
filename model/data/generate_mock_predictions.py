"""
Generate realistic mock inference predictions for all 8 candidate models.
Simulates expected zero-shot behaviour based on architecture characteristics:
  - Qwen2-VL / InternVL2: strong VLMs, high accuracy
  - Florence-2: OCR-only, good text but poor structure
  - Donut: zero-shot DocVQA, moderate JSON accuracy
  - SmolVLM-500M: smallest local, lower accuracy
  - moondream2: decent but struggles with numbers
  - MiniCPM-V: strong local model
  - Phi-3.5: solid vision-language
"""

import json
import random
from pathlib import Path

random.seed(42)

MODELS = {
    "server": {
        "qwen2-vl": {"cer": 0.04, "field_acc": 0.88, "parse_fail_rate": 0.00},
        "internvl2": {"cer": 0.05, "field_acc": 0.85, "parse_fail_rate": 0.00},
        "florence2": {"cer": 0.12, "field_acc": 0.62, "parse_fail_rate": 0.10},
        "donut": {"cer": 0.18, "field_acc": 0.55, "parse_fail_rate": 0.20},
    },
    "local": {
        "moondream": {"cer": 0.14, "field_acc": 0.65, "parse_fail_rate": 0.10},
        "smolvlm": {"cer": 0.20, "field_acc": 0.55, "parse_fail_rate": 0.15},
        "minicpm": {"cer": 0.08, "field_acc": 0.80, "parse_fail_rate": 0.00},
        "phi35": {"cer": 0.10, "field_acc": 0.75, "parse_fail_rate": 0.05},
    },
}

EXERCISE_TYPOS = {
    "Bench Press": ["Bench Pres", "bench press", "Bench  Press"],
    "Squat": ["Sqat", "squat", "Squats"],
    "Deadlift": ["Dead Lift", "deadlift", "DL"],
    "OHP": ["ohp", "Overhead Press", "OPH"],
    "Pull-ups": ["Pullups", "Pull ups", "pull-ups"],
}


def mangle_entry(entry: dict, field_acc: float) -> dict | None:
    out = dict(entry)
    for field in ["exercise", "sets", "reps", "weight_kg", "notes"]:
        if random.random() > field_acc:
            if field == "exercise":
                typos = EXERCISE_TYPOS.get(entry["exercise"])
                out["exercise"] = random.choice(typos) if typos else entry["exercise"] + "s"
            elif field in ("sets", "reps") and entry[field] is not None:
                out[field] = entry[field] + random.choice([-1, 1, 2])
            elif field == "weight_kg" and entry[field] is not None:
                out[field] = round(entry[field] + random.choice([-2.5, 2.5, 5.0]), 1)
            elif field == "notes":
                out["notes"] = None if entry["notes"] else "extra note"
    return out


def generate_for_model(model_name: str, profile: dict, gt_dir: Path, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for gt_path in sorted(gt_dir.glob("*.json")):
        if random.random() < profile["parse_fail_rate"]:
            # Simulate parse failure — write empty page
            (out_dir / gt_path.name).write_text('{"entries": []}')
            continue
        gt = json.loads(gt_path.read_text())
        entries = [mangle_entry(e, profile["field_acc"]) for e in gt["entries"]]
        (out_dir / gt_path.name).write_text(json.dumps({"entries": entries}, indent=2))


if __name__ == "__main__":
    gt_dir = Path("data/test")
    for inference_type, models in MODELS.items():
        for model_name, profile in models.items():
            out_dir = Path(f"data/predictions/{inference_type}/{model_name}")
            generate_for_model(model_name, profile, gt_dir, out_dir)
            print(
                f"  {inference_type}/{model_name}: "
                f"{len(list(out_dir.glob('*.json')))} predictions written"
            )
    print("Done.")
