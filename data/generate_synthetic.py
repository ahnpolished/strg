"""Generate synthetic handwritten workout journal test images."""
import datetime
import json
import random
import textwrap
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

EXERCISES = [
    "Bench Press", "Squat", "Deadlift", "OHP", "Pull-ups",
    "Row", "Incline Bench", "Leg Press", "Dips", "Curl",
    "Tricep Ext", "Lat Pulldown", "Cable Row", "RDL", "Hip Thrust",
]
NOTES_OPTIONS = [None, None, None, "PR!", "felt heavy", "easy day", "slow tempo", "pause reps"]

SESSIONS = [
    {
        "date": datetime.date(2026, 1, 6),
        "entries": [
            {"exercise": "Bench Press", "sets": 4, "reps": 8, "weight_kg": 80.0, "notes": "PR!"},
            {"exercise": "Incline Bench", "sets": 3, "reps": 10, "weight_kg": 60.0, "notes": None},
            {"exercise": "Dips", "sets": 3, "reps": 12, "weight_kg": None, "notes": None},
        ],
    },
    {
        "date": datetime.date(2026, 1, 8),
        "entries": [
            {"exercise": "Squat", "sets": 5, "reps": 5, "weight_kg": 100.0, "notes": "felt heavy"},
            {"exercise": "Leg Press", "sets": 3, "reps": 15, "weight_kg": 150.0, "notes": None},
            {"exercise": "RDL", "sets": 3, "reps": 10, "weight_kg": 70.0, "notes": None},
        ],
    },
    {
        "date": datetime.date(2026, 1, 10),
        "entries": [
            {"exercise": "Deadlift", "sets": 3, "reps": 5, "weight_kg": 120.0, "notes": "PR!"},
            {"exercise": "Row", "sets": 4, "reps": 8, "weight_kg": 70.0, "notes": None},
            {"exercise": "Pull-ups", "sets": 3, "reps": 8, "weight_kg": None, "notes": None},
        ],
    },
    {
        "date": datetime.date(2026, 1, 13),
        "entries": [
            {"exercise": "OHP", "sets": 4, "reps": 6, "weight_kg": 55.0, "notes": "slow tempo"},
            {"exercise": "Lateral Raise", "sets": 3, "reps": 15, "weight_kg": 12.0, "notes": None},
            {"exercise": "Tricep Ext", "sets": 3, "reps": 12, "weight_kg": 30.0, "notes": None},
        ],
    },
    {
        "date": datetime.date(2026, 1, 15),
        "entries": [
            {"exercise": "Bench Press", "sets": 4, "reps": 6, "weight_kg": 85.0, "notes": None},
            {"exercise": "Curl", "sets": 3, "reps": 12, "weight_kg": 15.0, "notes": None},
            {"exercise": "Cable Row", "sets": 3, "reps": 10, "weight_kg": 60.0, "notes": "easy day"},
        ],
    },
    {
        "date": datetime.date(2026, 1, 17),
        "entries": [
            {"exercise": "Squat", "sets": 4, "reps": 8, "weight_kg": 90.0, "notes": None},
            {"exercise": "Hip Thrust", "sets": 3, "reps": 12, "weight_kg": 80.0, "notes": None},
        ],
    },
    {
        "date": datetime.date(2026, 1, 20),
        "entries": [
            {"exercise": "Deadlift", "sets": 4, "reps": 4, "weight_kg": 130.0, "notes": "PR!"},
            {"exercise": "Lat Pulldown", "sets": 3, "reps": 10, "weight_kg": 65.0, "notes": None},
            {"exercise": "Face Pull", "sets": 3, "reps": 15, "weight_kg": 20.0, "notes": None},
        ],
    },
    {
        "date": datetime.date(2026, 1, 22),
        "entries": [
            {"exercise": "OHP", "sets": 5, "reps": 3, "weight_kg": 60.0, "notes": "pause reps"},
            {"exercise": "Pull-ups", "sets": 4, "reps": 6, "weight_kg": None, "notes": None},
        ],
    },
    {
        "date": datetime.date(2026, 1, 24),
        "entries": [
            {"exercise": "Bench Press", "sets": 3, "reps": 10, "weight_kg": 75.0, "notes": "easy day"},
            {"exercise": "Incline DB", "sets": 3, "reps": 12, "weight_kg": 28.0, "notes": None},
            {"exercise": "Dips", "sets": 3, "reps": 15, "weight_kg": None, "notes": None},
        ],
    },
    {
        "date": datetime.date(2026, 1, 27),
        "entries": [
            {"exercise": "Squat", "sets": 3, "reps": 5, "weight_kg": 105.0, "notes": "PR!"},
            {"exercise": "Leg Curl", "sets": 3, "reps": 12, "weight_kg": 40.0, "notes": None},
            {"exercise": "Calf Raise", "sets": 4, "reps": 20, "weight_kg": 60.0, "notes": None},
        ],
    },
]


def render_session(session: dict, path: Path) -> None:
    w, h = 800, 600
    img = Image.new("RGB", (w, h), color=(252, 248, 240))
    draw = ImageDraw.Draw(img)

    try:
        font_title = ImageFont.truetype("/System/Library/Fonts/Supplemental/Courier New.ttf", 22)
        font_body = ImageFont.truetype("/System/Library/Fonts/Supplemental/Courier New.ttf", 18)
        font_small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Courier New.ttf", 15)
    except OSError:
        font_title = ImageFont.load_default()
        font_body = font_title
        font_small = font_title

    # Ruled lines
    for y in range(60, h - 20, 30):
        draw.line([(30, y), (w - 30, y)], fill=(200, 210, 220), width=1)

    # Left margin line
    draw.line([(80, 20), (80, h - 20)], fill=(220, 180, 180), width=1)

    y = 30
    date_str = session["date"].strftime("%Y-%m-%d  (%a)")
    draw.text((90, y), date_str, fill=(20, 20, 120), font=font_title)
    y += 40

    for entry in session["entries"]:
        sets = entry["sets"]
        reps = entry["reps"]
        kg = entry["weight_kg"]
        notes = entry["notes"]

        sr_str = f"{sets}x{reps}" if sets and reps else ""
        kg_str = f"@ {kg}kg" if kg else ""
        note_str = f"  [{notes}]" if notes else ""

        line = f"  {entry['exercise']:<18} {sr_str:<8} {kg_str:<12}{note_str}"
        draw.text((90, y), line, fill=(30, 30, 30), font=font_body)
        y += 32

    # Slight noise / aging effect
    import random as _r
    pixels = img.load()
    for _ in range(3000):
        x = _r.randint(0, w - 1)
        yy = _r.randint(0, h - 1)
        v = _r.randint(220, 255)
        pixels[x, yy] = (v, v - 5, v - 10)

    img.save(path, "JPEG", quality=85)


def build_gt_json(session: dict) -> dict:
    return {
        "entries": [
            {
                "date": session["date"].isoformat(),
                "exercise": e["exercise"],
                "sets": e["sets"],
                "reps": e["reps"],
                "weight_kg": e["weight_kg"],
                "notes": e["notes"],
            }
            for e in session["entries"]
        ]
    }


if __name__ == "__main__":
    out = Path("data/test")
    out.mkdir(parents=True, exist_ok=True)
    for i, session in enumerate(SESSIONS, start=1):
        img_path = out / f"{i:03d}.jpg"
        json_path = out / f"{i:03d}.json"
        render_session(session, img_path)
        json_path.write_text(json.dumps(build_gt_json(session), indent=2))
        print(f"  {img_path.name}  {json_path.name}  ({len(session['entries'])} entries)")
    print(f"Done — {len(SESSIONS)} test samples in {out}/")
