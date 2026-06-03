"""Async CRUD operations for SQLAlchemy models."""

import datetime
from typing import Sequence

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from . import models, schemas


# =============================================================================
# Workout Sessions
# =============================================================================


async def create_workout_session(
    session: AsyncSession, data: schemas.WorkoutSessionCreate
) -> models.WorkoutSessionModel:
    """Create a workout session with its entries."""
    db_session = models.WorkoutSessionModel(
        date=data.date or datetime.datetime.now(datetime.timezone.utc),
        label=data.label,
    )
    session.add(db_session)
    await session.flush()

    for idx, entry_data in enumerate(data.entries):
        entry = models.WorkoutEntryModel(
            session_id=db_session.id,
            date=entry_data.date,
            exercise=entry_data.exercise,
            sets=entry_data.sets,
            reps=entry_data.reps,
            weight_kg=entry_data.weight_kg,
            weight_lbs=entry_data.weight_lbs,
            notes=entry_data.notes,
            sort_order=entry_data.sort_order or idx,
        )
        session.add(entry)

    await session.commit()

    # Re-fetch with eager-loaded entries to avoid lazy-load issues
    return await _get_with_entries(session, db_session.id)


async def list_workout_sessions(
    session: AsyncSession,
    year: int | None = None,
    month: int | None = None,
    limit: int = 50,
    offset: int = 0,
) -> Sequence[models.WorkoutSessionModel]:
    """List workout sessions, optionally filtered by year/month."""
    stmt = (
        select(models.WorkoutSessionModel)
        .options(selectinload(models.WorkoutSessionModel.entries))
        .order_by(models.WorkoutSessionModel.date.desc())
    )

    if year is not None and month is not None:
        import calendar

        last_day = calendar.monthrange(year, month)[1]
        start = datetime.datetime(year, month, 1, tzinfo=datetime.timezone.utc)
        end = datetime.datetime(year, month, last_day, 23, 59, 59, tzinfo=datetime.timezone.utc)
        stmt = stmt.where(
            models.WorkoutSessionModel.date >= start,
            models.WorkoutSessionModel.date <= end,
        )

    stmt = stmt.offset(offset).limit(limit)
    result = await session.execute(stmt)
    return result.scalars().all()


async def get_workout_session(
    session: AsyncSession, session_id: str
) -> models.WorkoutSessionModel | None:
    """Get a single workout session with its entries."""
    return await _get_with_entries(session, session_id)


async def update_workout_session(
    session: AsyncSession, session_id: str, data: schemas.WorkoutSessionUpdate
) -> models.WorkoutSessionModel | None:
    """Update a workout session's metadata (label, date)."""
    db_session = await _get_with_entries(session, session_id)
    if db_session is None:
        return None
    if data.label is not None:
        db_session.label = data.label
    if data.date is not None:
        db_session.date = data.date
    await session.commit()

    # Re-fetch with eager entries
    return await _get_with_entries(session, session_id)


async def delete_workout_session(session: AsyncSession, session_id: str) -> bool:
    """Delete a workout session and its entries (cascade)."""
    db_session = await _get_with_entries(session, session_id)
    if db_session is None:
        return False
    await session.delete(db_session)
    await session.commit()
    return True


async def set_workout_entries(
    session: AsyncSession,
    session_id: str,
    entries_data: list[schemas.WorkoutEntryCreate],
) -> models.WorkoutSessionModel | None:
    """Replace all entries for a session."""
    db_session = await _get_with_entries(session, session_id)
    if db_session is None:
        return None

    # Remove existing entries through the relationship (cascade delete-orphan)
    db_session.entries.clear()
    await session.flush()

    # Add new entries via the relationship
    for idx, entry_data in enumerate(entries_data):
        entry = models.WorkoutEntryModel(
            date=entry_data.date,
            exercise=entry_data.exercise,
            sets=entry_data.sets,
            reps=entry_data.reps,
            weight_kg=entry_data.weight_kg,
            weight_lbs=entry_data.weight_lbs,
            notes=entry_data.notes,
            sort_order=entry_data.sort_order or idx,
        )
        db_session.entries.append(entry)

    await session.commit()

    # Re-fetch with eager entries
    return await _get_with_entries(session, session_id)


async def get_sessions_by_day(
    session: AsyncSession, year: int, month: int
) -> dict[int, schemas.WorkoutSessionOut]:
    """Get sessions keyed by day-of-month for calendar view."""
    import calendar

    last_day = calendar.monthrange(year, month)[1]
    start = datetime.datetime(year, month, 1, tzinfo=datetime.timezone.utc)
    end = datetime.datetime(year, month, last_day, 23, 59, 59, tzinfo=datetime.timezone.utc)

    stmt = (
        select(models.WorkoutSessionModel)
        .where(
            models.WorkoutSessionModel.date >= start,
            models.WorkoutSessionModel.date <= end,
        )
        .options(selectinload(models.WorkoutSessionModel.entries))
        .order_by(models.WorkoutSessionModel.date.desc())
    )
    result = await session.execute(stmt)
    sessions = result.scalars().all()

    by_day: dict[int, schemas.WorkoutSessionOut] = {}
    for s in sessions:
        day = s.date.day
        by_day[day] = _session_to_out(s)
    return by_day


# =============================================================================
# User Preferences
# =============================================================================


async def get_or_create_preferences(
    session: AsyncSession,
) -> models.UserPreferencesModel:
    """Get the latest user preferences, creating defaults if none exist."""
    stmt = (
        select(models.UserPreferencesModel)
        .order_by(models.UserPreferencesModel.updated_at.desc())
        .limit(1)
    )
    result = await session.execute(stmt)
    prefs = result.scalar_one_or_none()
    if prefs is None:
        prefs = models.UserPreferencesModel()
        session.add(prefs)
        await session.commit()
        await session.refresh(prefs)
    return prefs


async def update_preferences(
    session: AsyncSession, data: schemas.UserPreferencesCreate
) -> models.UserPreferencesModel:
    """Update user preferences. Creates a new row so history is preserved."""
    prefs = models.UserPreferencesModel(
        notation_order=data.notation_order,
        separator=data.separator,
        sets_reps=data.sets_reps,
        unit=data.unit,
    )
    session.add(prefs)
    await session.commit()
    await session.refresh(prefs)
    return prefs


# =============================================================================
# Feedback
# =============================================================================


async def create_feedback(
    session: AsyncSession,
    image_path: str,
    entries_json: str,
    original_entries_json: str | None = None,
    notes: str | None = None,
) -> models.FeedbackSubmissionModel:
    """Record a feedback submission."""
    fb = models.FeedbackSubmissionModel(
        image_path=image_path,
        entries_json=entries_json,
        original_entries_json=original_entries_json,
        notes=notes,
    )
    session.add(fb)
    await session.commit()
    await session.refresh(fb)
    return fb


# =============================================================================
# Internal Helpers
# =============================================================================


async def _get_with_entries(
    session: AsyncSession, session_id: str
) -> models.WorkoutSessionModel | None:
    stmt = (
        select(models.WorkoutSessionModel)
        .where(models.WorkoutSessionModel.id == session_id)
        .options(selectinload(models.WorkoutSessionModel.entries))
    )
    result = await session.execute(stmt)
    return result.scalar_one_or_none()


def _session_to_out(s: models.WorkoutSessionModel) -> schemas.WorkoutSessionOut:
    return schemas.WorkoutSessionOut(
        id=s.id,
        date=s.date,
        label=s.label,
        created_at=s.created_at,
        entry_count=len(s.entries) if s.entries else 0,
    )


def _session_to_detail(s: models.WorkoutSessionModel) -> schemas.WorkoutSessionDetailOut:
    return schemas.WorkoutSessionDetailOut(
        id=s.id,
        date=s.date,
        label=s.label,
        created_at=s.created_at,
        entries=[_entry_to_out(e) for e in (s.entries or [])],
    )


def _entry_to_out(e: models.WorkoutEntryModel) -> schemas.WorkoutEntryOut:
    return schemas.WorkoutEntryOut(
        id=e.id,
        date=e.date,
        exercise=e.exercise,
        sets=e.sets,
        reps=e.reps,
        weight_kg=e.weight_kg,
        weight_lbs=e.weight_lbs,
        notes=e.notes,
        sort_order=e.sort_order,
    )
