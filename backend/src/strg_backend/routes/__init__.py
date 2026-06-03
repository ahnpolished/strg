"""Route package — empty init makes routes importable."""

from . import feedback, health, preferences, workouts

__all__ = ["health", "workouts", "preferences", "feedback"]
