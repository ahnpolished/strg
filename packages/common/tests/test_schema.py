import datetime
import json
import tempfile
from pathlib import Path

import pytest

from common.schema import WorkoutEntry, WorkoutPage, dump_page, entries_to_text, load_page


def make_entry(**kwargs) -> WorkoutEntry:
    defaults = {
        "date": datetime.date(2026, 1, 15),
        "exercise": "bench press",
        "sets": 3,
        "reps": 10,
        "weight_kg": 80.0,
        "notes": None,
    }
    return WorkoutEntry(**{**defaults, **kwargs})


def test_workout_entry_required_fields():
    entry = WorkoutEntry(date=datetime.date(2026, 1, 1), exercise="squat")
    assert entry.sets is None
    assert entry.reps is None
    assert entry.weight_kg is None
    assert entry.notes is None


def test_workout_entry_all_fields():
    entry = make_entry()
    assert entry.exercise == "bench press"
    assert entry.sets == 3
    assert entry.reps == 10
    assert entry.weight_kg == 80.0


def test_workout_page_empty():
    page = WorkoutPage()
    assert page.entries == []


def test_workout_page_with_entries():
    page = WorkoutPage(entries=[make_entry(), make_entry(exercise="squat")])
    assert len(page.entries) == 2


def test_round_trip_json():
    page = WorkoutPage(entries=[make_entry(), make_entry(exercise="deadlift", notes="pb")])
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        path = Path(f.name)
    dump_page(page, path)
    loaded = load_page(path)
    assert loaded == page
    path.unlink()


def test_entries_to_text_all_fields():
    entry = make_entry()
    text = entries_to_text(entry)
    assert "bench press" in text
    assert "80.0" in text
    assert "2026-01-15" in text


def test_entries_to_text_null_fields_omitted():
    entry = WorkoutEntry(date=datetime.date(2026, 1, 1), exercise="pull-up")
    text = entries_to_text(entry)
    assert "pull-up" in text
    assert "None" not in text
