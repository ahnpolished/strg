"""SQLAlchemy async ORM models for the strg backend."""

import datetime
import uuid

from sqlalchemy import DateTime, Float, ForeignKey, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .database import Base


def _utcnow() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def _new_id() -> str:
    return uuid.uuid4().hex[:12]


# ---------------------------------------------------------------------------
# WorkoutSession
# ---------------------------------------------------------------------------


class WorkoutSessionModel(Base):
    __tablename__ = "workout_sessions"

    id: Mapped[str] = mapped_column(String(24), primary_key=True, default=_new_id)
    date: Mapped[datetime.datetime] = mapped_column(DateTime, nullable=False, default=_utcnow)
    label: Mapped[str] = mapped_column(String(128), nullable=False, default="WORKOUT")
    created_at: Mapped[datetime.datetime] = mapped_column(
        DateTime, nullable=False, default=_utcnow, server_default=func.now()
    )

    entries: Mapped[list["WorkoutEntryModel"]] = relationship(
        back_populates="session", cascade="all, delete-orphan", order_by="WorkoutEntryModel.sort_order"
    )


# ---------------------------------------------------------------------------
# WorkoutEntry
# ---------------------------------------------------------------------------


class WorkoutEntryModel(Base):
    __tablename__ = "workout_entries"

    id: Mapped[str] = mapped_column(String(24), primary_key=True, default=_new_id)
    session_id: Mapped[str] = mapped_column(
        String(24), ForeignKey("workout_sessions.id", ondelete="CASCADE"), nullable=False
    )
    date: Mapped[str | None] = mapped_column(String(16), nullable=True)
    exercise: Mapped[str] = mapped_column(String(256), nullable=False)
    sets: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    reps: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    weight_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    weight_lbs: Mapped[float | None] = mapped_column(Float, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    session: Mapped["WorkoutSessionModel"] = relationship(back_populates="entries")


# ---------------------------------------------------------------------------
# UserPreferences
# ---------------------------------------------------------------------------


class UserPreferencesModel(Base):
    __tablename__ = "user_preferences"

    id: Mapped[str] = mapped_column(String(24), primary_key=True, default=_new_id)
    notation_order: Mapped[str] = mapped_column(String(10), nullable=False, default="nwrn")
    separator: Mapped[str] = mapped_column(String(10), nullable=False, default="pipe")
    sets_reps: Mapped[str] = mapped_column(String(10), nullable=False, default="x")
    unit: Mapped[str] = mapped_column(String(6), nullable=False, default="LBS")
    created_at: Mapped[datetime.datetime] = mapped_column(
        DateTime, nullable=False, default=_utcnow, server_default=func.now()
    )
    updated_at: Mapped[datetime.datetime] = mapped_column(
        DateTime, nullable=False, default=_utcnow, server_default=func.now(), onupdate=_utcnow
    )


# ---------------------------------------------------------------------------
# FeedbackSubmission
# ---------------------------------------------------------------------------


class FeedbackSubmissionModel(Base):
    __tablename__ = "feedback_submissions"

    id: Mapped[str] = mapped_column(String(24), primary_key=True, default=_new_id)
    image_path: Mapped[str] = mapped_column(String(512), nullable=False)
    entries_json: Mapped[str] = mapped_column(Text, nullable=False)
    original_entries_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    submitted_at: Mapped[datetime.datetime] = mapped_column(
        DateTime, nullable=False, default=_utcnow, server_default=func.now()
    )
