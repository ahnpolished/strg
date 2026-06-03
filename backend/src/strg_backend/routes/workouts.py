"""Workout session CRUD endpoints."""

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud, schemas
from ..database import get_session

router = APIRouter(prefix="/workouts", tags=["workouts"])


@router.post("", response_model=schemas.WorkoutSessionDetailOut, status_code=201)
async def create_workout(
    data: schemas.WorkoutSessionCreate,
    session: AsyncSession = Depends(get_session),
) -> schemas.WorkoutSessionDetailOut:
    """Create a new workout session with entries."""
    db_session = await crud.create_workout_session(session, data)
    return crud._session_to_detail(db_session)


@router.get("", response_model=list[schemas.WorkoutSessionOut])
async def list_workouts(
    year: int | None = Query(None, ge=2020),
    month: int | None = Query(None, ge=1, le=12),
    limit: int = Query(50, ge=1, le=250),
    offset: int = Query(0, ge=0),
    session: AsyncSession = Depends(get_session),
) -> list[schemas.WorkoutSessionOut]:
    """List workout sessions, optionally filtered by year/month (calendar view)."""
    rows = await crud.list_workout_sessions(session, year=year, month=month, limit=limit, offset=offset)
    return [crud._session_to_out(r) for r in rows]


@router.get("/calendar", response_model=dict[str, schemas.WorkoutSessionOut])
async def calendar_view(
    year: int = Query(..., ge=2020),
    month: int = Query(..., ge=1, le=12),
    session: AsyncSession = Depends(get_session),
) -> dict[str, schemas.WorkoutSessionOut]:
    """Get sessions keyed by day-of-month for the calendar view."""
    by_day = await crud.get_sessions_by_day(session, year=year, month=month)
    # Convert int keys to str for JSON
    return {str(k): v for k, v in by_day.items()}


@router.get("/{session_id}", response_model=schemas.WorkoutSessionDetailOut)
async def get_workout(
    session_id: str,
    session: AsyncSession = Depends(get_session),
) -> schemas.WorkoutSessionDetailOut:
    """Get a single workout session with all entries."""
    db_session = await crud.get_workout_session(session, session_id)
    if db_session is None:
        raise HTTPException(status_code=404, detail="Workout session not found")
    return crud._session_to_detail(db_session)


@router.patch("/{session_id}", response_model=schemas.WorkoutSessionDetailOut)
async def update_workout(
    session_id: str,
    data: schemas.WorkoutSessionUpdate,
    session: AsyncSession = Depends(get_session),
) -> schemas.WorkoutSessionDetailOut:
    """Update a workout session's metadata."""
    db_session = await crud.update_workout_session(session, session_id, data)
    if db_session is None:
        raise HTTPException(status_code=404, detail="Workout session not found")
    return crud._session_to_detail(db_session)


@router.delete("/{session_id}", status_code=204)
async def delete_workout(
    session_id: str,
    session: AsyncSession = Depends(get_session),
) -> None:
    """Delete a workout session and all its entries."""
    deleted = await crud.delete_workout_session(session, session_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="Workout session not found")


@router.put("/{session_id}/entries", response_model=schemas.WorkoutSessionDetailOut)
async def set_entries(
    session_id: str,
    data: list[schemas.WorkoutEntryCreate],
    session: AsyncSession = Depends(get_session),
) -> schemas.WorkoutSessionDetailOut:
    """Replace all entries for a session (edit workflow)."""
    db_session = await crud.set_workout_entries(session, session_id, data)
    if db_session is None:
        raise HTTPException(status_code=404, detail="Workout session not found")
    return crud._session_to_detail(db_session)
