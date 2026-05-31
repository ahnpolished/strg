import datetime

from common.schema import WorkoutEntry, WorkoutPage

from evaluation.metrics import FIELDS, cer, evaluate_pages, field_match


def entry(exercise="bench press", sets=3, reps=10, weight_kg=80.0, notes=None):
    return WorkoutEntry(
        date=datetime.date(2026, 1, 15),
        exercise=exercise,
        sets=sets,
        reps=reps,
        weight_kg=weight_kg,
        notes=notes,
    )


# --- CER ---


def test_cer_identical():
    assert cer("hello", "hello") == 0.0


def test_cer_empty_reference():
    assert cer("", "") == 0.0
    assert cer("text", "") == 1.0


def test_cer_one_char_diff():
    score = cer("hell", "hello")
    assert 0.0 < score < 1.0


def test_cer_completely_wrong():
    score = cer("xxxx", "hello")
    assert score > 0.0


# --- Field match ---


def test_field_match_all_correct():
    e = entry()
    matches = field_match(e, e)
    assert all(matches.values())


def test_field_match_exercise_case_insensitive():
    e1 = entry(exercise="Bench Press")
    e2 = entry(exercise="bench press")
    assert field_match(e1, e2)["exercise"] is True


def test_field_match_wrong_sets():
    e1 = entry(sets=3)
    e2 = entry(sets=4)
    assert field_match(e1, e2)["sets"] is False


def test_field_match_none_notes():
    e1 = entry(notes=None)
    e2 = entry(notes="")
    assert field_match(e1, e2)["notes"] is True


# --- evaluate_pages ---


def test_evaluate_pages_perfect():
    page = WorkoutPage(entries=[entry()])
    result = evaluate_pages("photo1", page, page)
    assert result["avg_cer"] == 0.0
    assert result["macro_field_accuracy"] == 1.0
    assert len(result["rows"]) == len(FIELDS)


def test_evaluate_pages_rows_structure():
    page = WorkoutPage(entries=[entry()])
    result = evaluate_pages("photo1", page, page)
    for row in result["rows"]:
        assert set(row.keys()) == {"photo_id", "field", "predicted", "ground_truth", "match"}


def test_evaluate_pages_empty_entries():
    empty = WorkoutPage(entries=[])
    result = evaluate_pages("photo1", empty, empty)
    assert result["avg_cer"] == 0.0
    assert result["entry_count"] == 0


def test_evaluate_pages_penalizes_missing_reference_entries():
    predicted = WorkoutPage(entries=[entry(exercise="bench")])
    reference = WorkoutPage(entries=[entry(exercise="bench"), entry(exercise="squat")])

    result = evaluate_pages("photo1", predicted, reference)

    assert result["reference_entry_count"] == 2
    assert result["predicted_entry_count"] == 1
    assert result["missing_entry_count"] == 1
    assert result["extra_entry_count"] == 0
    assert result["macro_field_accuracy"] < 1.0
    assert result["avg_cer"] > 0.0


def test_evaluate_pages_penalizes_extra_predicted_entries():
    predicted = WorkoutPage(entries=[entry(exercise="bench"), entry(exercise="curl")])
    reference = WorkoutPage(entries=[entry(exercise="bench")])

    result = evaluate_pages("photo1", predicted, reference)

    assert result["reference_entry_count"] == 1
    assert result["predicted_entry_count"] == 2
    assert result["missing_entry_count"] == 0
    assert result["extra_entry_count"] == 1
    assert result["macro_field_accuracy"] < 1.0
    assert result["avg_cer"] > 0.0
