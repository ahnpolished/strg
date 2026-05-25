import datetime
from pathlib import Path

from pydantic import BaseModel, Field


class WorkoutEntry(BaseModel):
    date: datetime.date
    exercise: str
    sets: int | None = None
    reps: int | None = None
    weight_kg: float | None = None
    weight_lbs: float | None = None
    notes: str | None = None


class WorkoutPage(BaseModel):
    entries: list[WorkoutEntry] = Field(default_factory=list)


def load_page(path: str | Path) -> WorkoutPage:
    return WorkoutPage.model_validate_json(Path(path).read_text())


def dump_page(page: WorkoutPage, path: str | Path) -> None:
    Path(path).write_text(page.model_dump_json(indent=2))


def load_entry(data: dict) -> WorkoutEntry:
    return WorkoutEntry.model_validate(data)


def entries_to_text(entry: WorkoutEntry) -> str:
    if entry.weight_kg is not None:
        weight_str = f"{entry.weight_kg}kg"
    elif entry.weight_lbs is not None:
        weight_str = f"{entry.weight_lbs}lbs"
    else:
        weight_str = ""
    parts = [
        str(entry.date),
        entry.exercise,
        str(entry.sets) if entry.sets is not None else "",
        str(entry.reps) if entry.reps is not None else "",
        weight_str,
        entry.notes or "",
    ]
    return " ".join(p for p in parts if p)
