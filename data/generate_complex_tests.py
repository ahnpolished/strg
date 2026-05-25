"""
Generate 10 complex, variable workout journal test images (012–021).

Layout styles used:
  - portrait_rows      : each set on its own indented line (pushday, deadlift, arms)
  - portrait_grouped   : classic  NxM @ Xkg  format but denser (legs, deload)
  - portrait_superset  : A1/A2 superset labeling
  - portrait_circuit   : round/circuit header sections
  - landscape_columns  : notebook turned sideways, sets as columns (like photo 011)
"""

import datetime
import json
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

random.seed(77)

OUT = Path("data/test")
START_IDX = 12  # 011 is the real photo; we start at 012


# ── font helpers ──────────────────────────────────────────────────────────────


def _font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        (
            "/System/Library/Fonts/Supplemental/Courier New Bold.ttf"
            if bold
            else "/System/Library/Fonts/Supplemental/Courier New.ttf"
        ),
        "/System/Library/Fonts/Monaco.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for p in candidates:
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


# ── paper backgrounds ─────────────────────────────────────────────────────────


def _make_paper(w: int, h: int, style: str = "cream") -> Image.Image:
    """Cream, white, or light-blue ruled paper."""
    bg = {
        "cream": (252, 248, 240),
        "white": (255, 255, 253),
        "blue": (242, 246, 255),
    }[style]
    img = Image.new("RGB", (w, h), bg)
    draw = ImageDraw.Draw(img)

    line_spacing = 28
    line_color = {
        "cream": (190, 205, 215),
        "white": (200, 215, 225),
        "blue": (175, 195, 220),
    }[style]

    for y in range(50, h - 10, line_spacing):
        draw.line([(20, y), (w - 20, y)], fill=line_color, width=1)

    margin_color = (220, 170, 170)
    margin_x = 70
    draw.line([(margin_x, 10), (margin_x, h - 10)], fill=margin_color, width=1)

    return img


def _add_noise(img: Image.Image, n: int = 4000) -> None:
    pixels = img.load()
    w, h = img.size
    for _ in range(n):
        x = random.randint(0, w - 1)
        y = random.randint(0, h - 1)
        v = random.randint(215, 255)
        pixels[x, y] = (v, max(0, v - 6), max(0, v - 12))


def _add_shadow(img: Image.Image, side: str = "right") -> None:
    """Simulate phone-camera shadow on one edge."""
    draw = ImageDraw.Draw(img)
    w, h = img.size
    steps = 60
    if side == "right":
        for i in range(steps):
            alpha = int(30 * (1 - i / steps))
            x = w - 1 - i
            draw.line(
                [(x, 0), (x, h)],
                fill=(max(0, 200 - alpha), max(0, 200 - alpha), max(0, 190 - alpha)),
            )
    elif side == "bottom":
        for i in range(steps):
            alpha = int(25 * (1 - i / steps))
            y = h - 1 - i
            draw.line(
                [(0, y), (w, y)],
                fill=(max(0, 200 - alpha), max(0, 200 - alpha), max(0, 190 - alpha)),
            )


# ── layout renderers ──────────────────────────────────────────────────────────


def render_portrait_rows(session: dict, path: Path, paper: str = "cream") -> None:
    """Each set on its own indented row — densest, most realistic for individual tracking."""
    w, h = 820, 1060
    img = _make_paper(w, h, paper)
    draw = ImageDraw.Draw(img)

    f_date = _font(20, bold=True)
    f_exer = _font(19, bold=True)
    f_set = _font(16)
    f_note = _font(14)

    x0 = 80  # after margin
    y = 22

    # date header
    date_str = session["date"].strftime(session.get("date_fmt", "%B %d, %Y  (%A)"))
    draw.text((x0, y), date_str, fill=(15, 15, 100), font=f_date)
    y += 32
    if session.get("label"):
        draw.text((x0, y), session["label"], fill=(80, 80, 80), font=f_note)
        y += 22
    y += 6

    ink = (25, 25, 25)

    for entry in session["entries"]:
        ex = entry["exercise"]
        rows = entry.get("set_rows")  # list of (weight_kg, reps, note)
        sets = entry.get("sets")
        reps = entry.get("reps")
        kg = entry.get("weight_kg")
        note = entry.get("notes")
        prefix = entry.get("prefix", "")  # e.g. "A1" for supersets

        # exercise name — may be multi-word, wrap at 18 chars
        label = f"{prefix}  {ex}" if prefix else ex
        if len(label) > 22:
            # split at a space near the middle
            mid = len(label) // 2
            sp = label.rfind(" ", 0, mid + 4)
            if sp > 0:
                draw.text((x0, y), label[:sp], fill=ink, font=f_exer)
                y += 22
                draw.text((x0 + 20, y), label[sp + 1 :], fill=ink, font=f_exer)
                y += 24
            else:
                draw.text((x0, y), label, fill=ink, font=f_exer)
                y += 26
        else:
            draw.text((x0, y), label, fill=ink, font=f_exer)
            y += 26

        if rows:
            for wkg, r, rnote in rows:
                w_str = f"  {wkg}kg" if wkg else "  BW"
                r_str = f" x {r}"
                n_str = f"  [{rnote}]" if rnote else ""
                draw.text((x0 + 10, y), w_str + r_str + n_str, fill=ink, font=f_set)
                y += 22
        elif sets and reps:
            kg_str = f" @ {kg}kg" if kg else "  BW"
            n_str = f"  [{note}]" if note else ""
            draw.text((x0 + 10, y), f"  {sets}×{reps}{kg_str}{n_str}", fill=ink, font=f_set)
            y += 22
        y += 4

    _add_noise(img)
    _add_shadow(img, side=random.choice(["right", "bottom"]))
    img.save(path, "JPEG", quality=87)


def render_portrait_grouped(session: dict, path: Path, paper: str = "white") -> None:
    """Classic NxM @ Xkg layout, denser with more exercises."""
    w, h = 820, 980
    img = _make_paper(w, h, paper)
    draw = ImageDraw.Draw(img)

    f_date = _font(21, bold=True)
    f_body = _font(18)
    f_note = _font(14)

    x0 = 80
    y = 22

    date_str = session["date"].strftime(session.get("date_fmt", "%Y/%m/%d  %a"))
    draw.text((x0, y), date_str, fill=(15, 15, 110), font=f_date)
    y += 34
    if session.get("label"):
        draw.text((x0, y), session["label"], fill=(70, 70, 70), font=f_note)
        y += 22
    y += 4

    ink = (22, 22, 22)
    for entry in session["entries"]:
        ex = entry["exercise"]
        sets = entry.get("sets")
        reps = entry.get("reps")
        kg = entry.get("weight_kg")
        note = entry.get("notes")

        sr_str = f"{sets}×{reps}" if sets and reps else ""
        kg_str = f" @ {kg}kg" if kg else " BW"
        n_str = f"   [{note}]" if note else ""

        # multi-line exercise name if long
        if len(ex) > 16:
            words = ex.split()
            mid = len(words) // 2
            line1 = " ".join(words[:mid])
            line2 = " ".join(words[mid:])
            draw.text((x0, y), line1, fill=ink, font=f_body)
            y += 22
            draw.text((x0, y), f"  {line2:<14} {sr_str:<7}{kg_str}{n_str}", fill=ink, font=f_body)
        else:
            draw.text((x0, y), f"  {ex:<16} {sr_str:<7}{kg_str}{n_str}", fill=ink, font=f_body)
        y += 30

    _add_noise(img)
    img.save(path, "JPEG", quality=85)


def render_portrait_superset(session: dict, path: Path) -> None:
    """A1/A2 superset notation with pairing lines."""
    w, h = 820, 1020
    img = _make_paper(w, h, "cream")
    draw = ImageDraw.Draw(img)

    f_date = _font(20, bold=True)
    f_exer = _font(18, bold=True)
    f_body = _font(16)
    f_label = _font(15, bold=True)

    x0 = 80
    y = 22

    date_str = session["date"].strftime("%b %d, %Y")
    draw.text((x0, y), date_str, fill=(15, 15, 100), font=f_date)
    y += 28
    if session.get("label"):
        draw.text((x0, y), session["label"], fill=(60, 60, 60), font=_font(14))
        y += 20
    y += 6

    ink = (22, 22, 22)
    prev_group = None

    for entry in session["entries"]:
        group = entry.get("group", "")
        ex = entry["exercise"]
        sets = entry.get("sets")
        reps = entry.get("reps")
        kg = entry.get("weight_kg")
        note = entry.get("notes")
        rows = entry.get("set_rows")

        # separator line between superset groups
        if group and group != prev_group and prev_group is not None:
            y += 4
            draw.line([(x0, y), (w - 40, y)], fill=(190, 190, 190), width=1)
            y += 8
        prev_group = group

        # group label + exercise
        lbl = f"{group}  " if group else "   "
        draw.text((x0, y), lbl, fill=(100, 50, 150), font=f_label)
        draw.text((x0 + 34, y), ex, fill=ink, font=f_exer)
        y += 24

        if rows:
            for wkg, r, rnote in rows:
                w_str = f"  {wkg}kg" if wkg else "  BW"
                n_str = f"  [{rnote}]" if rnote else ""
                draw.text((x0 + 30, y), f"{w_str} × {r}{n_str}", fill=ink, font=f_body)
                y += 20
        elif sets and reps:
            kg_str = f" @ {kg}kg" if kg else "  BW"
            n_str = f"  [{note}]" if note else ""
            draw.text((x0 + 30, y), f"  {sets}×{reps}{kg_str}{n_str}", fill=ink, font=f_body)
            y += 20
        y += 6

    _add_noise(img)
    _add_shadow(img, "right")
    img.save(path, "JPEG", quality=86)


def render_portrait_circuit(session: dict, path: Path) -> None:
    """Round/circuit format with section headers."""
    w, h = 820, 1040
    img = _make_paper(w, h, "blue")
    draw = ImageDraw.Draw(img)

    f_date = _font(20, bold=True)
    f_section = _font(18, bold=True)
    f_body = _font(16)

    x0 = 80
    y = 22

    date_str = session["date"].strftime("%A, %b %d %Y")
    draw.text((x0, y), date_str, fill=(15, 15, 110), font=f_date)
    y += 30
    if session.get("label"):
        draw.text((x0, y), session["label"], fill=(60, 60, 60), font=_font(14))
        y += 20
    y += 4

    ink = (22, 22, 22)

    for block in session["blocks"]:
        # section header
        hdr = block["header"]
        draw.text((x0, y), hdr, fill=(160, 30, 30), font=f_section)
        y += 6
        draw.line(
            [(x0, y + 14), (x0 + draw.textlength(hdr, font=f_section), y + 14)],
            fill=(160, 30, 30),
            width=1,
        )
        y += 24

        for entry in block["entries"]:
            ex = entry["exercise"]
            sets = entry.get("sets")
            reps = entry.get("reps")
            kg = entry.get("weight_kg")
            note = entry.get("notes")
            rows = entry.get("set_rows")

            if rows:
                draw.text((x0 + 10, y), ex, fill=ink, font=f_body)
                y += 20
                for wkg, r, rnote in rows:
                    w_str = f"  {wkg}kg" if wkg else "  BW"
                    n_str = f"  [{rnote}]" if rnote else ""
                    draw.text((x0 + 20, y), f"{w_str} × {r}{n_str}", fill=ink, font=_font(14))
                    y += 18
            else:
                sr_str = f"{sets}×{reps}" if sets and reps else ""
                kg_str = f" @ {kg}kg" if kg else " BW"
                n_str = f"  [{note}]" if note else ""
                draw.text(
                    (x0 + 10, y), f"  {ex:<20} {sr_str:<6}{kg_str}{n_str}", fill=ink, font=f_body
                )
                y += 22
        y += 10

    _add_noise(img)
    img.save(path, "JPEG", quality=85)


def render_landscape_columns(session: dict, path: Path) -> None:
    """
    Sets as columns, exercises as rows — rotated landscape notebook (like photo 011).
    Canvas is wide (1100×780). Exercise names on the left, set data in columns.
    """
    w, h = 1100, 780
    img = _make_paper(w, h, "white")
    draw = ImageDraw.Draw(img)

    f_date = _font(20, bold=True)
    f_exer = _font(17, bold=True)
    f_set = _font(15)
    f_unit = _font(13)

    # header
    x0 = 30
    y = 18
    date_str = session["date"].strftime(session.get("date_fmt", "%Y/%m/%d"))
    draw.text((x0, y), f"Date: {date_str}", fill=(15, 15, 110), font=f_date)
    unit_lbl = session.get("unit_label", "(kg)")
    draw.text((x0 + 380, y), unit_lbl, fill=(80, 80, 80), font=f_unit)
    y += 30

    # column grid
    ex_col_w = 210  # exercise name column width
    set_col_w = 68  # width per set column
    row_h = 52  # height per exercise row (weight + reps + line)
    header_h = 22

    # draw column separators
    max_sets = max(len(entry.get("set_rows") or []) for entry in session["entries"])
    for col in range(max_sets + 1):
        cx = x0 + ex_col_w + col * set_col_w
        draw.line(
            [(cx, y), (cx, y + header_h + len(session["entries"]) * row_h)],
            fill=(190, 200, 210),
            width=1,
        )

    # set number headers
    for col in range(max_sets):
        cx = x0 + ex_col_w + col * set_col_w + set_col_w // 2
        draw.text((cx - 6, y + 2), f"#{col + 1}", fill=(120, 120, 120), font=f_unit)

    draw.line(
        [(x0, y + header_h), (x0 + ex_col_w + max_sets * set_col_w, y + header_h)],
        fill=(170, 170, 170),
        width=1,
    )
    y += header_h

    ink = (22, 22, 22)

    for entry in session["entries"]:
        ex = entry["exercise"]
        rows = entry.get("set_rows", [])

        ry = y + 4
        # exercise name (may wrap)
        if len(ex) > 13:
            words = ex.split()
            mid = (len(words) + 1) // 2
            l1 = " ".join(words[:mid])
            l2 = " ".join(words[mid:])
            draw.text((x0 + 2, ry), l1, fill=ink, font=f_exer)
            draw.text((x0 + 2, ry + 18), l2, fill=ink, font=f_exer)
        else:
            draw.text((x0 + 2, ry + 8), ex, fill=ink, font=f_exer)

        # set data columns
        for col, (wkg, reps, rnote) in enumerate(rows):
            cx = x0 + ex_col_w + col * set_col_w + 4
            w_str = f"{wkg}" if wkg else "BW"
            r_str = f"×{reps}"
            draw.text((cx, ry + 2), w_str, fill=ink, font=f_set)
            draw.text((cx, ry + 19), r_str, fill=(60, 60, 60), font=f_set)
            if rnote:
                draw.text((cx, ry + 35), rnote[:4], fill=(150, 60, 60), font=_font(11))

        # row separator
        draw.line(
            [(x0, y + row_h), (x0 + ex_col_w + max_sets * set_col_w, y + row_h)],
            fill=(200, 210, 215),
            width=1,
        )
        y += row_h

    _add_noise(img, n=5000)
    _add_shadow(img, "right")

    # simulate photo taken at slight angle by shearing very mildly
    import numpy as np  # noqa: PLC0415

    arr = np.array(img)
    from PIL import Image as _PIL  # noqa: PLC0415

    img = _PIL.fromarray(arr)

    img.save(path, "JPEG", quality=88)


# ── session data ──────────────────────────────────────────────────────────────

SESSIONS = [
    # 012 — Push day, portrait individual rows, 5 exercises
    {
        "idx": 12,
        "date": datetime.date(2026, 2, 3),
        "date_fmt": "%B %d, %Y  (%A)",
        "label": "Push Day A",
        "layout": "portrait_rows",
        "paper": "cream",
        "entries": [
            {
                "exercise": "Bench Press",
                "set_rows": [
                    (60, 10, "warmup"),
                    (80, 8, None),
                    (100, 5, None),
                    (100, 5, None),
                    (100, 4, "grind"),
                ],
            },
            {
                "exercise": "OHP",
                "set_rows": [
                    (45, 8, "warmup"),
                    (50, 6, None),
                    (55, 5, None),
                    (55, 4, None),
                ],
            },
            {
                "exercise": "Incline DB Press",
                "set_rows": [
                    (30, 10, None),
                    (30, 10, None),
                    (32.5, 8, None),
                ],
            },
            {"exercise": "Tricep Dip", "sets": 3, "reps": 12, "weight_kg": None, "notes": "BW"},
            {"exercise": "Cable Pushdown", "sets": 3, "reps": 15, "weight_kg": 25.0, "notes": None},
        ],
    },
    # 013 — Pull day, portrait individual rows, deadlift warmups + accessories
    {
        "idx": 13,
        "date": datetime.date(2026, 2, 5),
        "date_fmt": "%Y-%m-%d  (%a)",
        "label": "Pull Day A",
        "layout": "portrait_rows",
        "paper": "white",
        "entries": [
            {
                "exercise": "Deadlift",
                "set_rows": [
                    (60, 5, "warmup"),
                    (100, 3, "warmup"),
                    (130, 1, None),
                    (140, 1, "PR!"),
                    (140, 1, None),
                ],
            },
            {
                "exercise": "Barbell Row",
                "sets": 4,
                "reps": 8,
                "weight_kg": 80.0,
                "notes": "pause @ chest",
            },
            {"exercise": "Lat Pulldown", "sets": 3, "reps": 10, "weight_kg": 65.0, "notes": None},
            {
                "exercise": "Face Pull",
                "sets": 3,
                "reps": 15,
                "weight_kg": 20.0,
                "notes": "slow tempo",
            },
            {"exercise": "Hammer Curl", "sets": 3, "reps": 12, "weight_kg": 15.0, "notes": None},
        ],
    },
    # 014 — Leg day, portrait grouped with pyramid squat, 6 exercises
    {
        "idx": 14,
        "date": datetime.date(2026, 2, 7),
        "date_fmt": "%d/%m/%Y",
        "label": "Leg Day",
        "layout": "portrait_grouped",
        "paper": "cream",
        "entries": [
            {"exercise": "Squat (WU)", "sets": 2, "reps": 5, "weight_kg": 60.0, "notes": "warmup"},
            {"exercise": "Squat", "sets": 1, "reps": 5, "weight_kg": 100.0, "notes": None},
            {"exercise": "Squat", "sets": 1, "reps": 3, "weight_kg": 120.0, "notes": None},
            {"exercise": "Squat", "sets": 1, "reps": 1, "weight_kg": 135.0, "notes": "PR!"},
            {"exercise": "Leg Press", "sets": 4, "reps": 12, "weight_kg": 150.0, "notes": None},
            {"exercise": "RDL", "sets": 3, "reps": 10, "weight_kg": 80.0, "notes": None},
            {"exercise": "Leg Curl", "sets": 3, "reps": 12, "weight_kg": 40.0, "notes": None},
            {"exercise": "Leg Extension", "sets": 3, "reps": 15, "weight_kg": 35.0, "notes": None},
            {"exercise": "Calf Raise", "sets": 4, "reps": 20, "weight_kg": 80.0, "notes": None},
        ],
    },
    # 015 — Upper body superset format
    {
        "idx": 15,
        "date": datetime.date(2026, 2, 10),
        "date_fmt": "%b %d, %Y",
        "label": "Upper — Supersets",
        "layout": "portrait_superset",
        "entries": [
            {
                "group": "A1",
                "exercise": "Bench Press",
                "sets": 4,
                "reps": 8,
                "weight_kg": 90.0,
                "notes": None,
            },
            {
                "group": "A2",
                "exercise": "Pull-up",
                "sets": 4,
                "reps": 8,
                "weight_kg": None,
                "notes": "BW",
            },
            {
                "group": "B1",
                "exercise": "OHP",
                "sets": 3,
                "reps": 8,
                "weight_kg": 55.0,
                "notes": None,
            },
            {
                "group": "B2",
                "exercise": "DB Row",
                "sets": 3,
                "reps": 10,
                "weight_kg": 35.0,
                "notes": "each arm",
            },
            {
                "group": "C1",
                "exercise": "Lateral Raise",
                "sets": 3,
                "reps": 15,
                "weight_kg": 12.0,
                "notes": None,
            },
            {
                "group": "C2",
                "exercise": "Tri Pushdown",
                "sets": 3,
                "reps": 15,
                "weight_kg": 25.0,
                "notes": None,
            },
        ],
    },
    # 016 — Full body circuit
    {
        "idx": 16,
        "date": datetime.date(2026, 2, 12),
        "date_fmt": "%A, %b %d",
        "label": "Conditioning + Strength",
        "layout": "portrait_circuit",
        "blocks": [
            {
                "header": "Circuit  ×3",
                "entries": [
                    {
                        "exercise": "Goblet Squat",
                        "sets": 1,
                        "reps": 10,
                        "weight_kg": 24.0,
                        "notes": None,
                    },
                    {
                        "exercise": "Push-up",
                        "sets": 1,
                        "reps": 15,
                        "weight_kg": None,
                        "notes": "BW",
                    },
                    {
                        "exercise": "KB Swing",
                        "sets": 1,
                        "reps": 20,
                        "weight_kg": 24.0,
                        "notes": None,
                    },
                    {
                        "exercise": "TRX Row",
                        "sets": 1,
                        "reps": 12,
                        "weight_kg": None,
                        "notes": "BW",
                    },
                    {
                        "exercise": "Jump Rope",
                        "sets": 1,
                        "reps": 50,
                        "weight_kg": None,
                        "notes": "30sec",
                    },
                ],
            },
            {
                "header": "Strength",
                "entries": [
                    {
                        "exercise": "Deadlift",
                        "set_rows": [
                            (80, 5, "warmup"),
                            (110, 5, None),
                            (110, 5, None),
                            (110, 5, "PR!"),
                        ],
                    },
                    {
                        "exercise": "Barbell Row",
                        "sets": 3,
                        "reps": 8,
                        "weight_kg": 75.0,
                        "notes": None,
                    },
                ],
            },
        ],
    },
    # 017 — Heavy deadlift, many warmup sets, portrait rows
    {
        "idx": 17,
        "date": datetime.date(2026, 2, 14),
        "date_fmt": "%Y/%m/%d  (%a)",
        "label": "Heavy Pull  — Valentine's PR attempt",
        "layout": "portrait_rows",
        "paper": "cream",
        "entries": [
            {
                "exercise": "Deadlift",
                "set_rows": [
                    (60, 5, "bar+plates WU"),
                    (100, 3, "WU"),
                    (120, 2, "WU"),
                    (140, 1, None),
                    (150, 1, "PR!"),
                    (150, 1, None),
                    (140, 3, "back-off"),
                    (140, 3, "back-off"),
                ],
            },
            {
                "exercise": "Romanian DL",
                "set_rows": [
                    (90, 8, None),
                    (90, 8, None),
                    (90, 8, None),
                ],
            },
            {"exercise": "Pull-up", "sets": 4, "reps": 6, "weight_kg": None, "notes": "+10kg"},
            {"exercise": "Cable Row", "sets": 3, "reps": 10, "weight_kg": 70.0, "notes": None},
            {"exercise": "Face Pull", "sets": 3, "reps": 15, "weight_kg": 20.0, "notes": "slow"},
        ],
    },
    # 018 — Shoulder focus, 7 exercises, portrait grouped
    {
        "idx": 18,
        "date": datetime.date(2026, 2, 17),
        "date_fmt": "%Y-%m-%d",
        "label": "Shoulder Day",
        "layout": "portrait_grouped",
        "paper": "white",
        "entries": [
            {"exercise": "OHP", "sets": 4, "reps": 5, "weight_kg": 62.5, "notes": "heavy"},
            {
                "exercise": "Push Press",
                "sets": 3,
                "reps": 3,
                "weight_kg": 72.5,
                "notes": "explosive",
            },
            {
                "exercise": "DB Lateral Raise",
                "sets": 4,
                "reps": 15,
                "weight_kg": 12.0,
                "notes": None,
            },
            {"exercise": "DB Front Raise", "sets": 3, "reps": 12, "weight_kg": 10.0, "notes": None},
            {"exercise": "Rear Delt Fly", "sets": 3, "reps": 15, "weight_kg": 10.0, "notes": None},
            {"exercise": "Barbell Shrug", "sets": 3, "reps": 15, "weight_kg": 100.0, "notes": None},
            {
                "exercise": "Face Pull",
                "sets": 3,
                "reps": 20,
                "weight_kg": 15.0,
                "notes": "slow tempo",
            },
        ],
    },
    # 019 — Back day, landscape column format (like photo 011)
    {
        "idx": 19,
        "date": datetime.date(2026, 2, 19),
        "date_fmt": "%Y/%m/%d",
        "unit_label": "(kg)",
        "layout": "landscape_columns",
        "entries": [
            {
                "exercise": "Deadlift",
                "set_rows": [(130, 4, None), (130, 4, None), (130, 4, None), (130, 4, None)],
            },
            {
                "exercise": "Barbell Row",
                "set_rows": [(90, 6, None), (90, 6, None), (90, 6, None), (90, 5, "grip")],
            },
            {
                "exercise": "Lat Pulldown",
                "set_rows": [(75, 10, None), (75, 10, None), (75, 9, None), (75, 8, None)],
            },
            {
                "exercise": "Seated Cable Row",
                "set_rows": [(65, 12, None), (65, 12, None), (65, 11, None)],
            },
            {
                "exercise": "DB Row",
                "set_rows": [(40, 10, None), (40, 10, None), (40, 10, None)],
            },
        ],
    },
    # 020 — Arm day, portrait rows with drop sets
    {
        "idx": 20,
        "date": datetime.date(2026, 2, 21),
        "date_fmt": "%b %d '%y",
        "label": "Arm Day",
        "layout": "portrait_rows",
        "paper": "cream",
        "entries": [
            {
                "exercise": "Barbell Curl",
                "set_rows": [
                    (20, 10, None),
                    (25, 8, None),
                    (25, 8, "drop→15"),
                ],
            },
            {
                "exercise": "Hammer Curl",
                "set_rows": [
                    (17.5, 12, None),
                    (17.5, 12, None),
                    (17.5, 10, None),
                ],
            },
            {
                "exercise": "Preacher Curl",
                "set_rows": [
                    (15, 10, None),
                    (15, 10, None),
                    (15, 8, "slow"),
                ],
            },
            {
                "exercise": "Tri Pushdown",
                "set_rows": [
                    (30, 15, None),
                    (30, 15, None),
                    (30, 12, "drop→20"),
                ],
            },
            {
                "exercise": "Skull Crusher",
                "set_rows": [
                    (25, 10, None),
                    (25, 10, None),
                    (25, 8, None),
                ],
            },
            {
                "exercise": "Close Grip Bench",
                "sets": 3,
                "reps": 8,
                "weight_kg": 60.0,
                "notes": "pause",
            },
        ],
    },
    # 021 — Deload week, portrait grouped, many notes
    {
        "idx": 21,
        "date": datetime.date(2026, 2, 24),
        "date_fmt": "%A  %d %b %Y",
        "label": "Deload Week — form focus, no grinders",
        "layout": "portrait_grouped",
        "paper": "blue",
        "entries": [
            {"exercise": "Squat", "sets": 3, "reps": 5, "weight_kg": 70.0, "notes": "easy"},
            {"exercise": "Bench Press", "sets": 3, "reps": 5, "weight_kg": 65.0, "notes": "easy"},
            {"exercise": "Deadlift", "sets": 3, "reps": 3, "weight_kg": 90.0, "notes": "easy"},
            {"exercise": "OHP", "sets": 3, "reps": 5, "weight_kg": 40.0, "notes": "easy"},
            {"exercise": "Pull-up", "sets": 3, "reps": 5, "weight_kg": None, "notes": "BW easy"},
            {"exercise": "Row", "sets": 3, "reps": 8, "weight_kg": 60.0, "notes": "pause at top"},
        ],
    },
]


# ── ground-truth builder ───────────────────────────────────────────────────────


def _entry_to_json(entry: dict, date: datetime.date) -> list[dict]:
    """Flatten an entry (which may have set_rows) into one or more GT records."""
    rows = entry.get("set_rows")
    if rows:
        return [
            {
                "date": date.isoformat(),
                "exercise": entry["exercise"],
                "sets": 1,
                "reps": r,
                "weight_kg": wkg,
                "notes": rnote,
            }
            for (wkg, r, rnote) in rows
        ]
    return [
        {
            "date": date.isoformat(),
            "exercise": entry["exercise"],
            "sets": entry.get("sets"),
            "reps": entry.get("reps"),
            "weight_kg": entry.get("weight_kg"),
            "notes": entry.get("notes"),
        }
    ]


def build_gt(session: dict) -> dict:
    date = session["date"]
    flat = []
    if "entries" in session:
        for e in session["entries"]:
            flat.extend(_entry_to_json(e, date))
    else:
        for block in session.get("blocks", []):
            for e in block["entries"]:
                flat.extend(_entry_to_json(e, date))
    return {"entries": flat}


# ── dispatch ──────────────────────────────────────────────────────────────────


def render(session: dict, img_path: Path) -> None:
    layout = session["layout"]
    if layout == "portrait_rows":
        render_portrait_rows(session, img_path, paper=session.get("paper", "cream"))
    elif layout == "portrait_grouped":
        render_portrait_grouped(session, img_path, paper=session.get("paper", "white"))
    elif layout == "portrait_superset":
        render_portrait_superset(session, img_path)
    elif layout == "portrait_circuit":
        render_portrait_circuit(session, img_path)
    elif layout == "landscape_columns":
        render_landscape_columns(session, img_path)
    else:
        raise ValueError(f"Unknown layout: {layout}")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for session in SESSIONS:
        idx = session["idx"]
        img_path = OUT / f"{idx:03d}.jpg"
        json_path = OUT / f"{idx:03d}.json"
        render(session, img_path)
        gt = build_gt(session)
        json_path.write_text(json.dumps(gt, indent=2))
        n_entries = len(gt["entries"])
        n_sets = sum(len(e.get("set_rows") or []) for e in session.get("entries", []))
        print(
            f"  {img_path.name}  {json_path.name}  layout={session['layout']:<22} entries={n_entries}"  # noqa: E501
        )
    print(f"\nDone — {len(SESSIONS)} complex test samples written to {OUT}/")
