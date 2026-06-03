"""Health check endpoint."""

from fastapi import APIRouter

from ..schemas import HealthOut

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthOut)
async def health_check() -> HealthOut:
    return HealthOut(status="ok", version="0.1.0")
