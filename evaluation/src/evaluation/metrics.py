import editdistance
from common.schema import WorkoutEntry, WorkoutPage, entries_to_text


def cer(predicted: str, reference: str) -> float:
    if not reference:
        return 0.0 if not predicted else 1.0
    return editdistance.eval(predicted, reference) / len(reference)


def field_match(pred: WorkoutEntry, ref: WorkoutEntry) -> dict[str, bool]:
    return {
        "date": pred.date == ref.date,
        "exercise": (pred.exercise or "").strip().lower() == (ref.exercise or "").strip().lower(),
        "sets": pred.sets == ref.sets,
        "reps": pred.reps == ref.reps,
        "weight_kg": pred.weight_kg == ref.weight_kg,
        "weight_lbs": pred.weight_lbs == ref.weight_lbs,
        "notes": (pred.notes or "").strip().lower() == (ref.notes or "").strip().lower(),
    }


FIELDS = ["date", "exercise", "sets", "reps", "weight_kg", "weight_lbs", "notes"]


def _append_field_rows(
    rows: list[dict],
    per_field_matches: dict[str, list[bool]],
    *,
    photo_id: str,
    pred_entry: WorkoutEntry | None,
    ref_entry: WorkoutEntry | None,
) -> None:
    if pred_entry is not None and ref_entry is not None:
        matches = field_match(pred_entry, ref_entry)
    else:
        matches = {field: False for field in FIELDS}

    for field, match in matches.items():
        per_field_matches[field].append(match)
        rows.append(
            {
                "photo_id": photo_id,
                "field": field,
                "predicted": "" if pred_entry is None else str(getattr(pred_entry, field)),
                "ground_truth": "" if ref_entry is None else str(getattr(ref_entry, field)),
                "match": match,
            }
        )


def evaluate_pages(
    photo_id: str,
    predicted: WorkoutPage,
    reference: WorkoutPage,
) -> dict:
    rows = []
    per_field_matches: dict[str, list[bool]] = {f: [] for f in FIELDS}
    cer_scores: list[float] = []

    predicted_entry_count = len(predicted.entries)
    reference_entry_count = len(reference.entries)
    aligned_entry_count = min(predicted_entry_count, reference_entry_count)
    missing_entry_count = max(0, reference_entry_count - predicted_entry_count)
    extra_entry_count = max(0, predicted_entry_count - reference_entry_count)

    for pred_entry, ref_entry in zip(predicted.entries, reference.entries):
        pred_text = entries_to_text(pred_entry)
        ref_text = entries_to_text(ref_entry)
        cer_scores.append(cer(pred_text, ref_text))
        _append_field_rows(
            rows,
            per_field_matches,
            photo_id=photo_id,
            pred_entry=pred_entry,
            ref_entry=ref_entry,
        )

    for ref_entry in reference.entries[aligned_entry_count:]:
        ref_text = entries_to_text(ref_entry)
        cer_scores.append(cer("", ref_text))
        _append_field_rows(
            rows,
            per_field_matches,
            photo_id=photo_id,
            pred_entry=None,
            ref_entry=ref_entry,
        )

    for pred_entry in predicted.entries[aligned_entry_count:]:
        pred_text = entries_to_text(pred_entry)
        cer_scores.append(cer(pred_text, ""))
        _append_field_rows(
            rows,
            per_field_matches,
            photo_id=photo_id,
            pred_entry=pred_entry,
            ref_entry=None,
        )

    entry_count = len(cer_scores)
    avg_cer = sum(cer_scores) / entry_count if entry_count else 0.0
    field_accuracy = {f: sum(v) / len(v) if v else 0.0 for f, v in per_field_matches.items()}
    macro_field_accuracy = sum(field_accuracy.values()) / len(FIELDS)

    return {
        "rows": rows,
        "avg_cer": avg_cer,
        "field_accuracy": field_accuracy,
        "macro_field_accuracy": macro_field_accuracy,
        "entry_count": entry_count,
        "predicted_entry_count": predicted_entry_count,
        "reference_entry_count": reference_entry_count,
        "missing_entry_count": missing_entry_count,
        "extra_entry_count": extra_entry_count,
    }
