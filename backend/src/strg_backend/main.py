"""strg-backend: FastAPI application."""

from contextlib import asynccontextmanager

from fastapi import FastAPI

from .database import create_tables
from .routes import feedback, health, preferences, workouts


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Create database tables on startup."""
    await create_tables()
    yield


app = FastAPI(
    title="strg Backend API",
    description="Workout data persistence backend for the strg iOS app.",
    version="0.1.0",
    lifespan=lifespan,
)

# Register routers
app.include_router(health.router)
app.include_router(workouts.router)
app.include_router(preferences.router)
app.include_router(feedback.router)
