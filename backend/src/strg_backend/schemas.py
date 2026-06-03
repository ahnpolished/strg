"""Pydantic schemas for API request/response validation."""

import datetime

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# WorkoutEntry
# ---------------------------------------------------------------------------


class WorkoutEntryCreate(BaseModel):
    """Schema for creating a single workout entry."""

    date: str | None = None
    exercise: str
    sets: int = Field(ge=0, default=1)
    reps: int = Field(ge=0, default=1)
    weight_kg: float | None = None
    weight_lbs: float | None = None
    notes: str | None = None
    sort_order: int = 0


class WorkoutEntryOut(BaseModel):
    """Schema returned by the API for a workout entry."""

    id: str
    date: str | None = None
    exercise: str
    sets: int
    reps: int
    weight_kg: float | None = None
    weight_lbs: float | None = None
    notes: str | None = None
    sort_order: int = 0

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# WorkoutSession
# ---------------------------------------------------------------------------


class WorkoutSessionCreate(BaseModel):
    """Schema for creating a workout session (the body of POST /workouts)."""

    date: datetime.datetime | None = None
    label: str = "WORKOUT"
    entries: list[WorkoutEntryCreate] = Field(default_factory=list)


class WorkoutSessionOut(BaseModel):
    """Schema returned by the API for a workout session (without entries)."""

    id: str
    date: datetime.datetime
    label: str
    created_at: datetime.datetime
    entry_count: int = 0

    model_config = {"from_attributes": True}


class WorkoutSessionDetailOut(BaseModel):
    """Full session with entries."""

    id: str
    date: datetime.datetime
    label: str
    created_at: datetime.datetime
    entries: list[WorkoutEntryOut] = Field(default_factory=list)

    model_config = {"from_attributes": True}


class WorkoutSessionUpdate(BaseModel):
    """Schema for updating a workout session."""

    label: str | None = None
    date: datetime.datetime | None = None


# ---------------------------------------------------------------------------
# UserPreferences
# ---------------------------------------------------------------------------


class UserPreferencesCreate(BaseModel):
    """Schema for creating/updating user preferences."""

    notation_order: str = "nwrn"
    separator: str = "pipe"
    sets_reps: str = "x"
    unit: str = "LBS"


class UserPreferencesOut(BaseModel):
    """Schema returned by the API for user preferences."""

    id: str
    notation_order: str
    separator: str
    sets_reps: str
    unit: str
    created_at: datetime.datetime
    updated_at: datetime.datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------


class HealthOut(BaseModel):
    status: str = "ok"
    version: str = "0.1.0"


# ---------------------------------------------------------------------------
# Feedback
# ---------------------------------------------------------------------------


class FeedbackOut(BaseModel):
    status: str = "ok"
    feedback_id: str
    entries_saved: int


# ---------------------------------------------------------------------------
# Prediction (proxy from model server)
# ---------------------------------------------------------------------------


class PredictionResponse(BaseModel):
    entries: list[WorkoutEntryCreate] = Field(default_factory=list)
    latency_s: float = 0.0
    entry_count: int = 0
