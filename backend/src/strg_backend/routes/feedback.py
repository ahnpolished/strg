"""Feedback submission endpoint — stores corrected entries for future fine-tuning."""

import json
import os
import time
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud, schemas
from ..database import get_session

FEEDBACK_UPLOAD_DIR = Path(
    os.environ.get("STRG_FEEDBACK_DIR", Path(__file__).resolve().parent.parent.parent.parent / "data" / "feedback")
)

router = APIRouter(prefix="/feedback", tags=["feedback"])


@router.post("", response_model=schemas.FeedbackOut, status_code=201)
async def submit_feedback(
    image: UploadFile = File(...),
    entries: str = Form(...),
    original_entries: str | None = Form(None),
    notes: str | None = Form(None),
    session: AsyncSession = Depends(get_session),
) -> schemas.FeedbackOut:
    """Submit corrected workout data for future fine-tuning.

    Saves the photo + corrected entries to the filesystem and records
    metadata in the database.
    """
    if not image.content_type or not image.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Only image files are accepted")

    # Validate entries JSON
    try:
        parsed = json.loads(entries)
        if not isinstance(parsed, list):
            raise ValueError("entries must be a list")
    except (json.JSONDecodeError, ValueError) as e:
        raise HTTPException(status_code=400, detail=f"Invalid entries JSON: {e}") from e

    # Create feedback directory
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    feedback_id = f"feedback_{timestamp}"
    save_dir = FEEDBACK_UPLOAD_DIR / feedback_id
    save_dir.mkdir(parents=True, exist_ok=True)

    # Save image
    contents = await image.read()
    img_path = save_dir / "photo.jpg"
    img_path.write_bytes(contents)

    # Save to database
    db_fb = await crud.create_feedback(
        session,
        image_path=str(img_path),
        entries_json=entries,
        original_entries_json=original_entries,
        notes=notes,
    )

    return schemas.FeedbackOut(
        status="ok",
        feedback_id=db_fb.id,
        entries_saved=len(parsed),
    )
