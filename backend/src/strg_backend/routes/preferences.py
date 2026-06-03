"""User preferences endpoints — store notation / calibration settings."""

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud, schemas
from ..database import get_session

router = APIRouter(prefix="/preferences", tags=["preferences"])


@router.get("", response_model=schemas.UserPreferencesOut)
async def get_preferences(
    session: AsyncSession = Depends(get_session),
) -> schemas.UserPreferencesOut:
    """Get the current user notation preferences (or defaults)."""
    prefs = await crud.get_or_create_preferences(session)
    return schemas.UserPreferencesOut.model_validate(prefs)


@router.put("", response_model=schemas.UserPreferencesOut)
async def update_preferences(
    data: schemas.UserPreferencesCreate,
    session: AsyncSession = Depends(get_session),
) -> schemas.UserPreferencesOut:
    """Update user notation / calibration preferences."""
    prefs = await crud.update_preferences(session, data)
    return schemas.UserPreferencesOut.model_validate(prefs)
