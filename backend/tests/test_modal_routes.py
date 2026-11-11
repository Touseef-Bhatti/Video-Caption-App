"""Serverless HTTP behavior using the existing authenticated API fixtures."""
import uuid
from unittest.mock import Mock

from models.models import JobStatus, ProcessingJob, Project
from services import chunked_upload_service as chunks
from tests.test_chunked_upload_routes import client, session_factory, USER1, CHUNK  # noqa: F401


async def test_cancel_remains_recorded_if_scheduler_is_unavailable(client, session_factory, monkeypatch):
    from routes import job_routes

    async with session_factory() as session:
        project = Project(id=str(uuid.uuid4()), user_id=USER1, name="Cancel test", original_filename="clip.mp4")
        session.add(project)
        job = ProcessingJob(project_id=project.id, status=JobStatus.queued, celery_task_id="fc-queued")
        session.add(job)
        await session.commit()
        job_id = job.id
    stop = Mock(side_effect=ConnectionError("scheduler offline"))
    monkeypatch.setattr(job_routes, "cancel_task", stop)
    response = await client.post(f"/api/jobs/{job_id}/cancel")
    assert response.status_code == 200
    assert response.json()["status"] == "cancelled"
    stop.assert_called_once_with("fc-queued")
    async with session_factory() as session:
        assert (await session.get(ProcessingJob, job_id)).status == JobStatus.cancelled


async def test_chunk_route_resumes_after_local_files_are_lost(client, monkeypatch, tmp_path):
    from app.config import get_settings

    settings = get_settings()
    monkeypatch.setattr(settings, "temp_storage_dir", str(tmp_path / "first-container"))
    monkeypatch.setattr(settings, "chunk_storage_backend", "object_storage")
    objects = {}
    monkeypatch.setattr(chunks.storage_service, "upload_file", lambda p, k: objects.update({k: p.read_bytes()}))
    monkeypatch.setattr(chunks.storage_service, "list_keys", lambda prefix: [k for k in objects if k.startswith(prefix)])
    response = await client.post("/api/uploads/init", json={
        "file_name": "clip.mp4", "content_type": "video/mp4", "total_size_bytes": CHUNK,
        "project_name": "Resume test", "chunk_size_bytes": CHUNK,
    })
    upload_id = response.json()["upload_id"]
    response = await client.put(f"/api/uploads/{upload_id}/chunks/0", content=b"x" * CHUNK)
    assert response.status_code == 200
    monkeypatch.setattr(settings, "temp_storage_dir", str(tmp_path / "new-container"))
    response = await client.get(f"/api/uploads/{upload_id}/status")
    assert response.json()["received_chunks"] == [0]
