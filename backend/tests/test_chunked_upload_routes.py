"""
HTTP-level tests of the resumable upload flow, run against an in-memory
SQLite database (not Postgres) with storage and Celery mocked out. A real
tiny MP4 is generated with ffmpeg so the final validate/probe step runs for
real. These prove the route logic (init, chunk rules, resume-by-status,
complete, cancel, ownership); they do not prove anything about Postgres,
S3, or Celery themselves.
"""
from __future__ import annotations
import subprocess
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import StaticPool

from app.config import get_settings
from app.database import Base, get_db
from app.main import app
from app.security import get_current_user_id
from models import models
from models.models import Project, ProcessingJob, UploadSession, User
from services import upload_finalize_service

settings = get_settings()
CHUNK = 1024 * 1024  # smallest chunk size the API allows
USER1 = str(uuid.uuid4())
USER2 = str(uuid.uuid4())


@pytest.fixture(autouse=True)
def _temp_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "temp_storage_dir", str(tmp_path / "tmp"))


@pytest.fixture
def real_mp4(tmp_path) -> bytes:
    out = tmp_path / "t.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=duration=2:size=160x120:rate=10",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-shortest",
         "-c:v", "libx264", "-c:a", "aac", str(out)],
        check=True, capture_output=True,
    )
    return out.read_bytes()


@pytest_asyncio.fixture
async def session_factory():
    engine = create_async_engine("sqlite+aiosqlite://", poolclass=StaticPool, connect_args={"check_same_thread": False})
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as s:
        s.add(User(id=USER1, email="a@example.com", password_hash="x"))
        s.add(User(id=USER2, email="b@example.com", password_hash="x"))
        await s.commit()
    yield factory
    await engine.dispose()


@pytest_asyncio.fixture
async def client(session_factory, monkeypatch):
    uploaded, enqueued = [], []
    monkeypatch.setattr(upload_finalize_service.storage_service, "upload_file", lambda p, k: uploaded.append(k))
    monkeypatch.setattr(upload_finalize_service.process_video_job, "delay", lambda job_id: enqueued.append(job_id))

    current_user = {"id": USER1}

    async def override_db():
        async with session_factory() as s:
            yield s

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_current_user_id] = lambda: current_user["id"]
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        c.uploaded, c.enqueued, c.current_user = uploaded, enqueued, current_user
        yield c
    app.dependency_overrides.clear()


async def _init(client, size, name="clip.mp4", mime="video/mp4"):
    return await client.post("/api/uploads/init", json={
        "file_name": name, "content_type": mime, "total_size_bytes": size,
        "project_name": "My Clip", "chunk_size_bytes": CHUNK,
    })


async def test_init_rejects_unsupported_mime(client):
    r = await _init(client, 5 * CHUNK, mime="application/pdf")
    assert r.status_code == 415


async def test_init_rejects_oversize(client):
    too_big = (settings.max_upload_size_mb + 1) * 1024 * 1024
    r = await _init(client, too_big)
    assert r.status_code == 413


async def test_init_computes_total_chunks(client):
    r = await _init(client, 2 * CHUNK + 10)
    assert r.status_code == 201
    assert r.json()["total_chunks"] == 3


async def test_chunk_size_rules(client):
    r = await _init(client, 2 * CHUNK + 10)
    uid = r.json()["upload_id"]
    url = lambda i: f"/api/uploads/{uid}/chunks/{i}"

    assert (await client.put(url(0), content=b"x" * (CHUNK + 1))).status_code == 413   # too big
    assert (await client.put(url(0), content=b"x" * (CHUNK - 1))).status_code == 400   # non-final must be exact
    assert (await client.put(url(5), content=b"x" * CHUNK)).status_code == 400          # bad index
    assert (await client.put(url(2), content=b"")).status_code == 400                   # empty
    assert (await client.put(url(2), content=b"y" * 10)).status_code == 200             # short final chunk ok


async def test_resume_flow_status_lists_only_arrived_chunks(client):
    r = await _init(client, 3 * CHUNK)
    uid = r.json()["upload_id"]
    await client.put(f"/api/uploads/{uid}/chunks/0", content=b"a" * CHUNK)
    await client.put(f"/api/uploads/{uid}/chunks/2", content=b"c" * CHUNK)  # chunk 1 "lost"

    status = (await client.get(f"/api/uploads/{uid}/status")).json()
    assert status["received_chunks"] == [0, 2]

    # Complete refuses while a chunk is missing.
    r = await client.post(f"/api/uploads/{uid}/complete")
    assert r.status_code == 400
    assert "1 of 3" in r.json()["detail"]

    # Retry re-PUT of an existing index is fine (idempotent).
    assert (await client.put(f"/api/uploads/{uid}/chunks/0", content=b"a" * CHUNK)).status_code == 200
    # Send only what was missing.
    assert (await client.put(f"/api/uploads/{uid}/chunks/1", content=b"b" * CHUNK)).status_code == 200
    assert (await client.get(f"/api/uploads/{uid}/status")).json()["received_chunks"] == [0, 1, 2]


async def test_complete_rejects_non_video_and_cleans_up(client, session_factory):
    r = await _init(client, CHUNK)
    uid = r.json()["upload_id"]
    await client.put(f"/api/uploads/{uid}/chunks/0", content=b"not a video" + b"\0" * (CHUNK - 11))
    r = await client.post(f"/api/uploads/{uid}/complete")
    assert r.status_code == 422
    assert client.enqueued == [] and client.uploaded == []
    async with session_factory() as s:
        assert (await s.scalars(select(Project))).all() == []   # nothing written on validation failure


async def test_full_upload_with_real_mp4_creates_project_and_job(client, session_factory, real_mp4):
    total = len(real_mp4)
    r = await _init(client, total)
    body = r.json()
    uid, n = body["upload_id"], body["total_chunks"]
    for i in range(n):
        piece = real_mp4[i * CHUNK:(i + 1) * CHUNK]
        assert (await client.put(f"/api/uploads/{uid}/chunks/{i}", content=piece)).status_code == 200

    r = await client.post(f"/api/uploads/{uid}/complete")
    assert r.status_code == 201, r.text
    out = r.json()
    assert client.enqueued == [out["job_id"]]
    assert len(client.uploaded) == 1

    async with session_factory() as s:
        project = await s.get(Project, out["project_id"])
        job = await s.get(ProcessingJob, out["job_id"])
        session = await s.get(UploadSession, uid)
        assert project.user_id == USER1 and project.name == "My Clip"
        assert job.project_id == project.id
        assert session.status == "completed"

    # A second /complete is refused, and chunk files are gone.
    assert (await client.post(f"/api/uploads/{uid}/complete")).status_code == 400


async def test_cancel_deletes_chunks_and_blocks_further_uploads(client, session_factory):
    r = await _init(client, 2 * CHUNK)
    uid = r.json()["upload_id"]
    await client.put(f"/api/uploads/{uid}/chunks/0", content=b"a" * CHUNK)
    assert (await client.delete(f"/api/uploads/{uid}")).status_code == 204

    assert (await client.put(f"/api/uploads/{uid}/chunks/1", content=b"b" * CHUNK)).status_code == 400
    async with session_factory() as s:
        assert (await s.get(UploadSession, uid)).status == "cancelled"


async def test_other_users_cannot_touch_an_upload(client):
    r = await _init(client, CHUNK)
    uid = r.json()["upload_id"]
    client.current_user["id"] = USER2
    assert (await client.get(f"/api/uploads/{uid}/status")).status_code == 404
    assert (await client.put(f"/api/uploads/{uid}/chunks/0", content=b"x" * CHUNK)).status_code == 404
    assert (await client.delete(f"/api/uploads/{uid}")).status_code == 404
