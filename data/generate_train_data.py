"""
Generate synthetic training images for fine-tuning.

Writes to data/train/ (NOT data/test/). Uses random seeds for variety across:
- Compact row layout (one row per set, tabular)
- Grouped layout (exercise header + per-set rep column)
- Mixed kg/lbs sessions
- Multi-exercise sessions with 6-18 entries

Usage:
  uv run python data/generate_train_data.py --count 100 --seed 42
"""

import argparse
import datetime
import json
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

EXERCISES_KG = [
    "Bench Press",
    "Squat",
    "Deadlift",
    "OHP",
    "Incline Bench",
    "RDL",
    "Barbell Row",
    "Hip Thrust",
    "Front Squat",
    "Close Grip Bench",
    "Overhead Press",
    "Sumo Deadlift",
    "Good Morning",
    "Hack Squat",
]
EXERCISES_LBS = [
    "Bench Press",
    "Squat",
    "Deadlift",
    "OHP",
    "Incline Bench",
    "Lat Pulldown",
    "Cable Row",
    "Leg Press",
    "Leg Curl",
    "Seated Row",
    "Tricep Pushdown",
    "Preacher Curl",
    "Face Pull",
    "Chest Fly",
]
BODYWEIGHT = ["Pull-ups", "Dips", "Push-ups", "Chin-ups"]
NOTES_OPTIONS = [
    None,
    None,
    None,
    None,
    "PR!",
    "felt heavy",
    "easy day",
    "slow tempo",
    "pause reps",
    "WU",
    "BW",
    "grip",
]

WEIGHTS_KG = [40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150]
WEIGHTS_LBS = [45, 95, 115, 135, 155, 185, 205, 225, 245, 275, 315, 365]


def _font(size: int):
    for path in [
        "/System/Library/Fonts/Supplemental/Courier New.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    ]:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


def _make_session(rng: random.Random, use_lbs: bool, layout: str) -> dict:
    date = datetime.date(2025, rng.randint(1, 12), rng.randint(1, 28))
    exercises = EXERCISES_LBS if use_lbs else EXERCISES_KG
    n_exercises = rng.randint(3, 6)
    chosen = rng.sample(exercises + BODYWEIGHT, min(n_exercises, len(exercises)))
    entries = []

    for ex in chosen:
        is_bw = ex in BODYWEIGHT
        n_sets = rng.randint(2, 5)
        base_reps = rng.choice([3, 4, 5, 6, 8, 10, 12])
        if use_lbs and not is_bw:
            weight = rng.choice(WEIGHTS_LBS)
        elif not is_bw:
            weight = rng.choice(WEIGHTS_KG)
        else:
            weight = None

        if layout == "compact":
            for s in range(n_sets):
                reps = base_reps + rng.randint(-1, 1)
                note = rng.choice(NOTES_OPTIONS) if s == 0 else None
                entry = {
                    "date": date.isoformat(),
                    "exercise": ex,
                    "sets": 1,
                    "reps": max(1, reps),
                    "weight_lbs" if use_lbs else "weight_kg": weight,
                    "notes": note,
                }
                if use_lbs:
                    entry["weight_kg"] = None
                else:
                    entry["weight_lbs"] = None
                entries.append(entry)
        else:
            note = rng.choice(NOTES_OPTIONS)
            entry = {
                "date": date.isoformat(),
                "exercise": ex,
                "sets": n_sets,
                "reps": base_reps,
                "weight_lbs" if use_lbs else "weight_kg": weight,
                "notes": note,
            }
            if use_lbs:
                entry["weight_kg"] = None
            else:
                entry["weight_lbs"] = None
            entries.append(entry)

    return {"date": date, "entries": entries}


def _render_compact(session: dict, rng: random.Random) -> Image.Image:
    """One row per set — the hard layout that photo-019 represents."""
    w, h = 800, max(400, 80 + len(session["entries"]) * 30)
    img = Image.new("RGB", (w, h), color=(252, 248, 240))
    draw = ImageDraw.Draw(img)
    font_title = _font(20)
    font_body = _font(17)

    for y in range(50, h - 20, 28):
        draw.line([(30, y), (w - 30, y)], fill=(200, 210, 220), width=1)
    draw.line([(70, 20), (70, h - 20)], fill=(220, 180, 180), width=1)

    y = 25
    draw.text((80, y), session["date"].strftime("%Y-%m-%d"), fill=(20, 20, 120), font=font_title)
    y += 35

    prev_ex = None
    for entry in session["entries"]:
        ex = entry["exercise"]
        label = "" if ex == prev_ex else ex
        prev_ex = ex
        wkg = entry.get("weight_kg")
        wlbs = entry.get("weight_lbs")
        w_str = f"{wkg}kg" if wkg else (f"{wlbs}lbs" if wlbs else "BW")
        reps = entry.get("reps", "")
        note = entry.get("notes") or ""
        line = f"  {label:<18} {reps:<5} {w_str:<10}  {note}"
        draw.text((80, y), line, fill=(30, 30, 30), font=font_body)
        y += 28

    _add_noise(img, rng)
    return img


def _render_tabular(session: dict, rng: random.Random) -> Image.Image:
    """Exercise header + NxM notation per row."""
    w, h = 800, max(350, 80 + len(session["entries"]) * 35)
    img = Image.new("RGB", (w, h), color=(250, 250, 245))
    draw = ImageDraw.Draw(img)
    font_title = _font(20)
    font_body = _font(18)

    for y in range(50, h - 20, 32):
        draw.line([(30, y), (w - 30, y)], fill=(210, 215, 225), width=1)
    draw.line([(70, 20), (70, h - 20)], fill=(210, 185, 185), width=1)

    y = 25
    draw.text((80, y), session["date"].strftime("%d/%m/%Y"), fill=(40, 40, 140), font=font_title)
    y += 40

    for entry in session["entries"]:
        sets = entry.get("sets", 1)
        reps = entry.get("reps", "")
        wkg = entry.get("weight_kg")
        wlbs = entry.get("weight_lbs")
        w_str = f"@ {wkg}kg" if wkg else (f"@ {wlbs}lbs" if wlbs else "BW")
        note = f"  [{entry['notes']}]" if entry.get("notes") else ""
        sr = f"{sets}x{reps}" if sets and reps else f"{reps}"
        line = f"  {entry['exercise']:<18} {sr:<8} {w_str:<14}{note}"
        draw.text((80, y), line, fill=(25, 25, 25), font=font_body)
        y += 33

    _add_noise(img, rng)
    return img


def _add_noise(img: Image.Image, rng: random.Random) -> None:
    pixels = img.load()
    w, h = img.size
    for _ in range(2000 + rng.randint(0, 1000)):
        x = rng.randint(0, w - 1)
        y = rng.randint(0, h - 1)
        v = rng.randint(215, 255)
        pixels[x, y] = (v, v - rng.randint(0, 8), v - rng.randint(0, 12))


def generate(count: int, seed: int, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    existing = len(list(out_dir.glob("*.jpg")))
    for i in range(count):
        idx = existing + i + 1
        use_lbs = rng.random() < 0.35
        layout = rng.choice(["compact", "compact", "tabular"])
        session = _make_session(rng, use_lbs, layout)
        if layout == "compact":
            img = _render_compact(session, rng)
        else:
            img = _render_tabular(session, rng)

        img_path = out_dir / f"{idx:04d}.jpg"
        json_path = out_dir / f"{idx:04d}.json"
        img.save(img_path, "JPEG", quality=85)
        gt = {
            "entries": [
                {k: v for k, v in e.items() if k != "date" or True} for e in session["entries"]
            ]
        }
        json_path.write_text(json.dumps(gt, indent=2))
        n = len(session["entries"])
        print(f"  {img_path.name}  layout={layout:<10}  entries={n}  {'lbs' if use_lbs else 'kg'}")

    print(f"\nDone — {count} training samples written to {out_dir}/")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out", type=Path, default=Path("data/train"))
    args = parser.parse_args()
    generate(args.count, args.seed, args.out)
