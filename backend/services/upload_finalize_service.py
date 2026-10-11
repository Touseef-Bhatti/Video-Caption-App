"""
The single place a locally-assembled video file (whether it arrived as one
direct multipart POST or as reassembled chunks) gets validated, persisted
to object storage, and turned into Project/Video/ProcessingJob rows plus
an enqueued Celery job. Both routes/video_routes.py's direct upload and
routes/chunked_upload_routes.py's /complete call this -- so a file can
never reach the job queue through one path with different rules than the
other.
"""
from __future__ import annotations
from pathlib import Path

from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from models.models import Project, Video, ProcessingJob, JobStatus
from services import ffmpeg_service, validation_service, storage_service
from workers.tasks import process_video_job

settings = get_settings()


class UploadValidationError(ValueError):
    """Raised with a user-safe message; the caller turns this into a 422."""


async def finalize_upload(
    *,
    local_path: Path,
    declared_mime: str,
    original_filename: str,
    project_name: str,
    caption_language: str = "auto",
    translate_to: str | None = None,
    size_bytes: int,
    user_id: str,
    db: AsyncSession,
) -> tuple[str, str]:
    """Validates the assembled file, and on success: uploads it to object
    storage, creates Project/Video/ProcessingJob, commits, enqueues the
    job, and returns (project_id, job_id). On validation failure, the
    local file is deleted and UploadValidationError is raised -- nothing
    is written to the database."""
    try:
        validation_service.validate_upload_basics(local_path, declared_mime, settings.allowed_mime_list, settings.max_upload_size_mb)
        probe = ffmpeg_service.probe_video(local_path)
        ffmpeg_service.validate_duration(probe, settings.max_video_duration_seconds)
    except ValueError as e:
        local_path.unlink(missing_ok=True)
        raise UploadValidationError(str(e))

    project = Project(user_id=user_id, name=project_name, original_filename=original_filename, status="queued")
    db.add(project)
    await db.flush()

    job = ProcessingJob(
        project_id=project.id, status=JobStatus.queued, stage="Queued", progress=0,
        caption_options={"caption_language": caption_language, "translate_to": translate_to},
    )
    db.add(job)
    await db.flush()

    storage_key = f"uploads/{project.id}/{validation_service.safe_filename(original_filename, job.id)}"
    storage_service.upload_file(local_path, storage_key)
    local_path.unlink(missing_ok=True)

    video = Video(
        project_id=project.id,
        storage_key=storage_key,
        mime_type=declared_mime,
        size_bytes=size_bytes,
        duration_seconds=probe.duration_seconds,
        width=probe.width,
        height=probe.height,
        has_audio=probe.has_audio,
    )
    db.add(video)
    await db.commit()

    process_video_job.delay(job.id)
    return project.id, job.id
