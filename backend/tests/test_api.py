"""Integration tests for the strg backend API."""

import io
import pytest
from httpx import ASGITransport, AsyncClient
from PIL import Image

from strg_backend.database import Base, create_tables, engine
from strg_backend.main import app


@pytest.fixture(autouse=True)
async def _setup_db():
    """Create and tear down tables around each test."""
    await create_tables()
    yield
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


@pytest.fixture
async def client():
    """Async HTTP test client."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_health(client: AsyncClient):
    resp = await client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["version"] == "0.1.0"


# ---------------------------------------------------------------------------
# Workouts
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_create_and_get_workout(client: AsyncClient):
    payload = {
        "label": "PUSH DAY",
        "entries": [
            {
                "exercise": "Bench Press",
                "sets": 4,
                "reps": 8,
                "weight_lbs": 135.0,
                "notes": "felt strong",
            },
            {
                "exercise": "OHP",
                "sets": 3,
                "reps": 10,
                "weight_lbs": 95.0,
            },
        ],
    }

    # Create
    resp = await client.post("/workouts", json=payload)
    assert resp.status_code == 201
    created = resp.json()
    assert created["label"] == "PUSH DAY"
    assert len(created["entries"]) == 2
    assert created["entries"][0]["exercise"] == "Bench Press"
    assert created["entries"][0]["weight_lbs"] == 135.0
    workout_id = created["id"]

    # Get by id
    resp = await client.get(f"/workouts/{workout_id}")
    assert resp.status_code == 200
    fetched = resp.json()
    assert fetched["id"] == workout_id
    assert len(fetched["entries"]) == 2


@pytest.mark.asyncio
async def test_list_workouts(client: AsyncClient):
    # Create a couple
    await client.post("/workouts", json={"label": "A", "entries": []})
    await client.post("/workouts", json={"label": "B", "entries": []})

    resp = await client.get("/workouts")
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 2


@pytest.mark.asyncio
async def test_update_workout(client: AsyncClient):
    resp = await client.post("/workouts", json={"label": "OLD", "entries": []})
    wid = resp.json()["id"]

    resp = await client.patch(f"/workouts/{wid}", json={"label": "NEW"})
    assert resp.status_code == 200
    assert resp.json()["label"] == "NEW"


@pytest.mark.asyncio
async def test_delete_workout(client: AsyncClient):
    resp = await client.post("/workouts", json={"label": "DELETE ME", "entries": []})
    wid = resp.json()["id"]

    resp = await client.delete(f"/workouts/{wid}")
    assert resp.status_code == 204

    resp = await client.get(f"/workouts/{wid}")
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_set_entries(client: AsyncClient):
    resp = await client.post("/workouts", json={"label": "EDIT", "entries": []})
    wid = resp.json()["id"]

    new_entries = [
        {"exercise": "Squat", "sets": 5, "reps": 5, "weight_kg": 100.0},
        {"exercise": "Deadlift", "sets": 3, "reps": 5, "weight_kg": 120.0, "notes": "PR"},
    ]
    resp = await client.put(f"/workouts/{wid}/entries", json=new_entries)
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["entries"]) == 2
    assert data["entries"][0]["exercise"] == "Squat"


@pytest.mark.asyncio
async def test_calendar_view(client: AsyncClient):
    await client.post(
        "/workouts",
        json={
            "label": "JAN",
            "date": "2026-01-15T08:00:00Z",
            "entries": [{"exercise": "Bench", "sets": 3, "reps": 8}],
        },
    )
    resp = await client.get("/workouts/calendar?year=2026&month=1")
    assert resp.status_code == 200
    data = resp.json()
    assert "15" in data
    assert data["15"]["label"] == "JAN"


@pytest.mark.asyncio
async def test_workout_not_found(client: AsyncClient):
    resp = await client.get("/workouts/nonexistent")
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Preferences
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_default_preferences(client: AsyncClient):
    resp = await client.get("/preferences")
    assert resp.status_code == 200
    data = resp.json()
    assert data["notation_order"] == "nwrn"
    assert data["separator"] == "pipe"
    assert data["unit"] == "LBS"


@pytest.mark.asyncio
async def test_update_preferences(client: AsyncClient):
    resp = await client.put(
        "/preferences",
        json={"notation_order": "nsw", "separator": "dash", "unit": "KG"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["notation_order"] == "nsw"
    assert data["separator"] == "dash"
    assert data["unit"] == "KG"

    # GET should return the updated one
    resp = await client.get("/preferences")
    assert resp.status_code == 200
    data = resp.json()
    assert data["notation_order"] == "nsw"


# ---------------------------------------------------------------------------
# Feedback
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_submit_feedback(client: AsyncClient):
    img = Image.new("RGB", (4, 4), color=(128, 0, 0))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    img_bytes = buf.getvalue()

    files = {"image": ("photo.jpg", io.BytesIO(img_bytes), "image/jpeg")}
    data = {
        "entries": '[{"exercise":"Bench Press","sets":4,"reps":8,"weight_lbs":135}]',
    }
    resp = await client.post("/feedback", files=files, data=data)
    assert resp.status_code == 201
    result = resp.json()
    assert result["status"] == "ok"
    assert result["entries_saved"] == 1
    assert "feedback_id" in result
