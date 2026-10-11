import uuid

from sqlalchemy import select

from models.models import Caption, Export, ProcessingJob, Project
from services.render_scene import caption_snapshot, fingerprint
from tests.test_chunked_upload_routes import client, session_factory, USER1, USER2  # noqa: F401


async def create_project(session_factory):
    project_id = str(uuid.uuid4())
    async with session_factory() as session:
        session.add(Project(id=project_id, user_id=USER1, name="Caption render test", original_filename="clip.mp4"))
        session.add(Caption(project_id=project_id, language="English", style_preset="neon",
            caption_data={"language": "English", "segments": []}, aspect_ratio="9:16"))
        await session.commit()
    return project_id


async def test_old_or_different_export_does_not_match(client, session_factory):
    project_id = await create_project(session_factory)
    async with session_factory() as session:
        session.add(Export(project_id=project_id, storage_key="old.mp4", quality="standard"))
        await session.commit()
    response = await client.get(f"/api/projects/{project_id}/captions")
    assert response.json()["matching_export_id"] is None
    assert response.json()["aspect_ratio"] == "9:16"


async def test_persist_format_and_only_select_matching_export(client, session_factory):
    project_id = await create_project(session_factory)
    response = await client.put(f"/api/projects/{project_id}/captions", json={
        "aspect_ratio": "1:1", "style_overrides": {"font_size": 60, "position_x": 0.2}})
    assert response.status_code == 200
    current = response.json()["render_fingerprint"]
    async with session_factory() as session:
        export = Export(project_id=project_id, storage_key="match.mp4", render_fingerprint=current)
        session.add(export)
        await session.commit()
        matching_id = export.id
        session.add(Export(project_id=project_id, storage_key="wrong.mp4", render_fingerprint="wrong"))
        await session.commit()
    data = (await client.get(f"/api/projects/{project_id}/captions")).json()
    assert data["matching_export_id"] == matching_id
    assert data["aspect_ratio"] == "1:1"
    await client.put(f"/api/projects/{project_id}/captions", json={"style_overrides": {"font_size": 61}})
    assert (await client.get(f"/api/projects/{project_id}/captions")).json()["matching_export_id"] is None


async def test_queued_render_keeps_original_settings_after_later_edits(client, session_factory, monkeypatch):
    from routes.caption_routes import rerender_project_job
    enqueued = []
    monkeypatch.setattr(rerender_project_job, "delay", lambda *args: enqueued.append(args))
    project_id = await create_project(session_factory)
    response = await client.post(f"/api/projects/{project_id}/render", json={"aspect_ratio": "4:5"})
    assert response.status_code == 201
    job_id = response.json()["job_id"]
    await client.put(f"/api/projects/{project_id}/captions", json={"style_preset": "comic", "aspect_ratio": "16:9"})
    async with session_factory() as session:
        job = await session.get(ProcessingJob, job_id)
        assert job.render_snapshot["style_preset"] == "neon"
        assert job.render_snapshot["aspect_ratio"] == "4:5"
        current = await session.scalar(select(Caption).where(Caption.project_id == project_id))
        assert fingerprint(job.render_snapshot) != fingerprint(caption_snapshot(current))
    assert enqueued == [(job_id, "standard", "4:5")]


async def test_caption_render_ownership(client, session_factory):
    project_id = await create_project(session_factory)
    client.current_user["id"] = USER2
    assert (await client.get(f"/api/projects/{project_id}/captions")).status_code == 404
    assert (await client.post(f"/api/projects/{project_id}/render")).status_code == 404
