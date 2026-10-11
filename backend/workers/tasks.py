"""
The actual processing pipeline. One Celery task per job, moving a
ProcessingJob through the state machine in section 29/58:

  queued -> preparing -> extracting_audio -> transcribing
  -> creating_captions -> rendering -> finalizing -> completed
                                               (or failed / cancelled at any step)

Never holds the full video in memory: every step reads/writes files on
disk (TEMP_STORAGE_DIR) and only the final output + the small JSON
transcript ever reach the database or object storage.
"""
from __future__ import annotations

import asyncio
import shutil
from pathlib import Path

from workers.celery_app import celery_app
from workers.db_sync import SyncSessionLocal
from app.config import get_settings
from models.models import ProcessingJob, Project, Video, Caption, Export, JobStatus, Usage
from services import ffmpeg_service, gemini_service, storage_service, flutter_render_service
from services.render_scene import caption_snapshot, fingerprint
from schemas.schemas import GeminiTranscriptResponse

settings = get_settings()


class JobCancelled(Exception):
    pass


def _update_job(session, job: ProcessingJob, *, status: JobStatus | None = None, stage: str | None = None,
                 progress: int | None = None, error: str | None = None):
    if status is not None:
        job.status = status
    if stage is not None:
        job.stage = stage
    if progress is not None:
        job.progress = progress
    if error is not None:
        job.error = error
    session.commit()


def _check_cancelled(session, job_id: str) -> None:
    session.expire_all()
    job = session.get(ProcessingJob, job_id)
    if job and job.status == JobStatus.cancelled:
        raise JobCancelled()


@celery_app.task(bind=True, name="workers.tasks.process_video_job")
def process_video_job(self, job_id: str) -> None:
    session = SyncSessionLocal()
    work_dir = Path(settings.temp_storage_dir) / "processing" / job_id
    work_dir.mkdir(parents=True, exist_ok=True)

    job = session.get(ProcessingJob, job_id)
    if job is None:
        session.close()
        return

    project = session.get(Project, job.project_id)
    video: Video = project.video

    try:
        job.celery_task_id = self.request.id
        _update_job(session, job, status=JobStatus.preparing, stage="Preparing video", progress=5)
        _check_cancelled(session, job_id)

        local_video_path = work_dir / "source.mp4"
        storage_service.download_file(video.storage_key, local_video_path)

        probe = ffmpeg_service.probe_video(local_video_path)
        ffmpeg_service.validate_duration(probe, settings.max_video_duration_seconds)

        if not probe.has_audio:
            raise ValueError("This video has no audio track, so captions can't be generated from it.")

        # ---- extract audio ----
        _update_job(session, job, status=JobStatus.extracting_audio, stage="Extracting audio", progress=15)
        _check_cancelled(session, job_id)
        audio_path = work_dir / "audio.wav"
        ffmpeg_service.extract_audio(local_video_path, audio_path)

        # ---- transcribe (chunked Gemini calls) ----
        _update_job(session, job, status=JobStatus.transcribing, stage="Analyzing speech", progress=30)
        _check_cancelled(session, job_id)
        caption_options = job.caption_options or {}
        transcript = asyncio.run(gemini_service.transcribe_audio(
            audio_path, probe.duration_seconds, work_dir / "chunks",
            caption_language=caption_options.get("caption_language", "auto"),
        ))
        translate_to = caption_options.get("translate_to")
        if translate_to and translate_to.strip().casefold() != transcript.language.strip().casefold():
            transcript = asyncio.run(gemini_service.translate_transcript(transcript, translate_to))

        # ---- persist caption data (editable by the user afterward) ----
        _update_job(session, job, status=JobStatus.creating_captions, stage="Creating captions", progress=55)
        _check_cancelled(session, job_id)
        caption = Caption(
            project_id=project.id,
            language=transcript.language,
            style_preset="classic",
            caption_data=transcript.model_dump(),
        )
        session.add(caption)
        session.commit()

        # ---- render ----
        _update_job(session, job, status=JobStatus.rendering, stage="Rendering video", progress=70)
        _check_cancelled(session, job_id)
        snapshot = caption_snapshot(caption)
        job.render_snapshot = snapshot
        session.commit()
        out_path = work_dir / "output.mp4"
        def on_progress(fraction):
            _check_cancelled(session, job_id)
            _update_job(session, job, progress=70 + int(fraction * 21))
        flutter_render_service.render_scene(
            local_video_path, snapshot, out_path, quality="standard", progress=on_progress)
        # ---- finalize: upload output, record export, clean up temp files ----
        _update_job(session, job, status=JobStatus.finalizing, stage="Finalizing", progress=92)
        _check_cancelled(session, job_id)
        export_key = f"exports/{project.id}/{job.id}.mp4"
        storage_service.upload_file(out_path, export_key)

        export = Export(project_id=project.id, storage_key=export_key, quality="standard", render_fingerprint=fingerprint(snapshot), job_id=job.id)
        session.add(export)

        project.duration_seconds = probe.duration_seconds
        project.status = "completed"
        # Usage is recorded only for original processing (the Gemini call);
        # re-renders reuse saved captions and cost no transcription.
        session.add(Usage(user_id=project.user_id, duration_processed_seconds=probe.duration_seconds))
        _update_job(session, job, status=JobStatus.completed, stage="Completed", progress=100)

    except JobCancelled:
        _update_job(session, job, status=JobStatus.cancelled, stage="Cancelled")
    except ValueError as e:
        # Expected/validation-style errors -> safe to show the message directly.
        _update_job(session, job, status=JobStatus.failed, stage="Failed", error=str(e))
    except Exception:
        # Unexpected errors -> log internally (celery's own logger captures the
        # traceback), but never leak internals to the user-facing job record.
        _update_job(
            session, job, status=JobStatus.failed, stage="Failed",
            error="We couldn't process this video right now. Please try again.",
        )
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
        session.close()


@celery_app.task(bind=True, name="workers.tasks.rerender_project_job")
def rerender_project_job(
    self,
    job_id: str,
    quality: str = "standard",
    aspect_ratio: str = "original",
) -> None:
    """
    Re-renders the final video from the CURRENTLY SAVED caption_data and
    style (preset + overrides) -- used after a user edits captions in the
    editor (text, per-word style, colors, preset, position) and wants a new
    export that reflects their changes.

    Deliberately skips the Gemini step entirely: the transcript already
    exists and the user may have hand-edited it, so re-running Gemini would
    both cost money for nothing and silently discard their edits (section
    56: never send the same audio to Gemini twice because of a workflow
    that doesn't need it).
    """
    session = SyncSessionLocal()
    work_dir = Path(settings.temp_storage_dir) / "processing" / job_id
    work_dir.mkdir(parents=True, exist_ok=True)

    job = session.get(ProcessingJob, job_id)
    if job is None:
        session.close()
        return
    project = session.get(Project, job.project_id)
    video: Video = project.video
    caption = session.query(Caption).filter(Caption.project_id == project.id).one_or_none()

    try:
        if caption is None:
            raise ValueError("No captions found for this project yet.")

        _update_job(session, job, status=JobStatus.preparing, stage="Preparing video", progress=10)
        _check_cancelled(session, job_id)
        local_video_path = work_dir / "source.mp4"
        storage_service.download_file(video.storage_key, local_video_path)
        probe = ffmpeg_service.probe_video(local_video_path)

        _update_job(session, job, status=JobStatus.rendering, stage="Rendering video", progress=50)
        _check_cancelled(session, job_id)
        # The queue carries an immutable snapshot; later edits must never change
        # the content of an already requested export.
        snapshot = job.render_snapshot
        if not snapshot:
            raise ValueError("This render predates the shared renderer. Please render again.")
        GeminiTranscriptResponse.model_validate(snapshot["caption_data"])
        out_path = work_dir / "output.mp4"
        def on_progress(fraction):
            _check_cancelled(session, job_id)
            _update_job(session, job, progress=50 + int(fraction * 41))
        flutter_render_service.render_scene(
            local_video_path, snapshot, out_path, quality=quality, progress=on_progress)
        _update_job(session, job, status=JobStatus.finalizing, stage="Finalizing", progress=92)
        _check_cancelled(session, job_id)
        export_key = f"exports/{project.id}/{job.id}.mp4"
        storage_service.upload_file(out_path, export_key)
        session.add(Export(project_id=project.id, storage_key=export_key, quality=quality, render_fingerprint=fingerprint(snapshot), job_id=job.id))
        project.status = "completed"
        _update_job(session, job, status=JobStatus.completed, stage="Completed", progress=100)

    except JobCancelled:
        _update_job(session, job, status=JobStatus.cancelled, stage="Cancelled")
    except ValueError as e:
        _update_job(session, job, status=JobStatus.failed, stage="Failed", error=str(e))
    except Exception:
        _update_job(
            session, job, status=JobStatus.failed, stage="Failed",
            error="We couldn't re-render this video right now. Please try again.",
        )
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
        session.close()


@celery_app.task(name="workers.tasks.cleanup_expired_files")
def cleanup_expired_files() -> None:
    """Scheduled periodically (see celery beat config in docker-compose).
    Deletes temp files older than TEMP_FILE_RETENTION_MINUTES and expired
    exports from object storage -- satisfies section 18/59. Also sweeps
    stale, never-completed upload sessions (section 59: 'cleanup expired
    uploads') so an abandoned chunked upload doesn't sit on disk forever."""
    import time
    cutoff = time.time() - settings.temp_file_retention_minutes * 60

    processing_dir = Path(settings.temp_storage_dir) / "processing"
    if processing_dir.exists():
        for child in processing_dir.iterdir():
            try:
                if child.stat().st_mtime < cutoff:
                    shutil.rmtree(child, ignore_errors=True)
            except FileNotFoundError:
                continue

    uploads_dir = Path(settings.temp_storage_dir) / "uploads"
    if uploads_dir.exists():
        for child in uploads_dir.iterdir():
            try:
                if child.stat().st_mtime < cutoff:
                    shutil.rmtree(child, ignore_errors=True)
            except FileNotFoundError:
                continue

    # Mark DB rows for sessions whose chunk directories are now gone (either
    # just cleaned up above, or already removed by a prior pass) so
    # GET /status reports them accurately instead of as silently "uploading"
    # forever.
    from models.models import UploadSession
    session = SyncSessionLocal()
    try:
        stale = session.query(UploadSession).filter(UploadSession.status == "uploading").all()
        for s in stale:
            if not (Path(settings.temp_storage_dir) / "uploads" / s.id).exists() and s.updated_at.timestamp() < cutoff:
                s.status = "cancelled"
        session.commit()
    finally:
        session.close()


def recover_orphaned_jobs() -> None:
    """Called once on backend startup (section 58). Any job still marked as
    an in-progress status when the process starts means a previous worker
    crashed mid-job -- those files are gone, so we fail them cleanly rather
    than leaving them stuck in 'processing' forever."""
    in_progress = [
        JobStatus.preparing, JobStatus.extracting_audio, JobStatus.transcribing,
        JobStatus.creating_captions, JobStatus.rendering, JobStatus.finalizing,
    ]
    session = SyncSessionLocal()
    try:
        stuck_jobs = session.query(ProcessingJob).filter(ProcessingJob.status.in_(in_progress)).all()
        for job in stuck_jobs:
            job.status = JobStatus.failed
            job.error = "Processing was interrupted by a server restart. Please try again."
        session.commit()
    finally:
        session.close()
