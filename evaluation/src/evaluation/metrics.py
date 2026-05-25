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
        "notes": (pred.notes or "").strip().lower() == (ref.notes or "").strip().lower(),
    }


FIELDS = ["date", "exercise", "sets", "reps", "weight_kg", "notes"]


def evaluate_pages(
    photo_id: str,
    predicted: WorkoutPage,
    reference: WorkoutPage,
) -> dict:
    rows = []
    per_field_matches: dict[str, list[bool]] = {f: [] for f in FIELDS}
    cer_scores: list[float] = []

    for pred_entry, ref_entry in zip(predicted.entries, reference.entries):
        pred_text = entries_to_text(pred_entry)
        ref_text = entries_to_text(ref_entry)
        cer_scores.append(cer(pred_text, ref_text))

        matches = field_match(pred_entry, ref_entry)
        for field, match in matches.items():
            per_field_matches[field].append(match)
            rows.append(
                {
                    "photo_id": photo_id,
                    "field": field,
                    "predicted": str(getattr(pred_entry, field)),
                    "ground_truth": str(getattr(ref_entry, field)),
                    "match": match,
                }
            )

    entry_count = len(cer_scores)
    avg_cer = sum(cer_scores) / entry_count if entry_count else 0.0
    field_accuracy = {
        f: sum(v) / len(v) if v else 0.0 for f, v in per_field_matches.items()
    }
    macro_field_accuracy = sum(field_accuracy.values()) / len(FIELDS)

    return {
        "rows": rows,
        "avg_cer": avg_cer,
        "field_accuracy": field_accuracy,
        "macro_field_accuracy": macro_field_accuracy,
        "entry_count": entry_count,
    }
