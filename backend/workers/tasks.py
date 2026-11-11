"""
The actual processing pipeline. One Celery task per job, moving a
ProcessingJob through the state machine in section 29/58:

  queued -> preparing -> extracting_audio -> transcribing
  -> creating_captions -> completed
  (or failed / cancelled at any step)

Never holds the full video in memory: every step reads/writes files on
disk (TEMP_STORAGE_DIR). Captions are saved to the database, and the final
video is rendered only after the user requests a download.
"""
from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import logging
import shutil
import time
from pathlib import Path

from workers.task_queue import task
from workers.db_sync import SyncSessionLocal
from app.config import get_settings
from models.models import ProcessingJob, Project, Video, Caption, Export, JobStatus, Usage
from services import ffmpeg_service, gemini_service, storage_service, flutter_render_service
from services.render_scene import caption_snapshot, fingerprint
from schemas.schemas import GeminiTranscriptResponse

settings = get_settings()
logger = logging.getLogger(__name__)


class JobCancelled(Exception):
    pass


def _run_async(coroutine_factory):
    """Run async service code away from Playwright's worker-thread loop.

    The persistent caption renderer keeps Playwright alive between Celery
    jobs. Playwright owns an asyncio loop in the task thread, so a later
    direct ``asyncio.run`` in that thread fails. A short-lived helper thread
    gives each transcription call a clean event loop while retaining the warm
    browser used by rendering.
    """
    with ThreadPoolExecutor(max_workers=1, thread_name_prefix="caption-async") as executor:
        return executor.submit(lambda: asyncio.run(coroutine_factory())).result()


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


def _save_diagnostics(session, job: ProcessingJob, diagnostics: dict) -> None:
    # Assign a new top-level object so SQLAlchemy reliably detects JSON changes.
    job.render_diagnostics = {**diagnostics}
    session.commit()


@task(bind=True, name="workers.tasks.process_video_job")
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
    diagnostics = {
        "schema_version": 1,
        "job_type": "initial_processing",
        "pipeline_phases_seconds": {},
    }

    try:
        _check_cancelled(session, job_id)
        job.celery_task_id = self.request.id
        _update_job(session, job, status=JobStatus.preparing, stage="Preparing video", progress=5)
        _check_cancelled(session, job_id)

        local_video_path = work_dir / "source.mp4"
        phase_started = time.perf_counter()
        storage_service.download_file(video.storage_key, local_video_path)
        diagnostics["pipeline_phases_seconds"]["source_download"] = round(time.perf_counter() - phase_started, 6)

        phase_started = time.perf_counter()
        probe = ffmpeg_service.probe_video(local_video_path)
        diagnostics["pipeline_phases_seconds"]["input_probe"] = round(time.perf_counter() - phase_started, 6)
        diagnostics["source"] = {
            "bytes": local_video_path.stat().st_size,
            "width": probe.width,
            "height": probe.height,
            "duration_seconds": probe.duration_seconds,
            "has_audio": probe.has_audio,
            "container": probe.mime_guess,
            "video_codec": probe.video_codec,
            "frame_rate": probe.frame_rate,
            "pixel_format": probe.pixel_format,
            "bit_rate": probe.bit_rate,
            "audio_codec": probe.audio_codec,
        }
        ffmpeg_service.validate_duration(probe, settings.max_video_duration_seconds)

        if not probe.has_audio:
            raise ValueError("This video has no audio track, so captions can't be generated from it.")

        # ---- extract audio ----
        _update_job(session, job, status=JobStatus.extracting_audio, stage="Extracting audio", progress=15)
        _check_cancelled(session, job_id)
        # FLAC preserves the 16 kHz mono speech while reducing the inline API
        # payload substantially compared with uncompressed PCM WAV.
        audio_path = work_dir / "audio.flac"
        phase_started = time.perf_counter()
        ffmpeg_service.extract_audio(local_video_path, audio_path)
        diagnostics["pipeline_phases_seconds"]["audio_extraction"] = round(time.perf_counter() - phase_started, 6)
        diagnostics["audio_extraction"] = {"output_bytes": audio_path.stat().st_size, "format": "FLAC", "sample_rate_hz": 16000, "channels": 1}

        # ---- transcribe (chunked Gemini calls) ----
        _update_job(session, job, status=JobStatus.transcribing, stage="Analyzing speech", progress=30)
        _check_cancelled(session, job_id)
        caption_options = job.caption_options or {}
        phase_started = time.perf_counter()
        transcript = _run_async(lambda: gemini_service.transcribe_audio(
            audio_path, probe.duration_seconds, work_dir / "chunks",
            caption_language=caption_options.get("caption_language", "auto"),
        ))
        diagnostics["pipeline_phases_seconds"]["transcription"] = round(time.perf_counter() - phase_started, 6)
        # ---- persist caption data (editable by the user afterward) ----
        _update_job(session, job, status=JobStatus.creating_captions, stage="Creating captions", progress=55)
        _check_cancelled(session, job_id)
        caption = Caption(
            project_id=project.id,
            language=transcript.language,
            style_preset="classic",
            caption_data={**transcript.model_dump(), "caption_script": "roman"},
        )
        session.add(caption)
        phase_started = time.perf_counter()
        session.commit()
        diagnostics["pipeline_phases_seconds"]["caption_database_write"] = round(time.perf_counter() - phase_started, 6)

        # Captions are previewed as a styled overlay in the editor. Defer the
        # expensive video render until the user requests a download.
        finalize_started = time.perf_counter()
        _check_cancelled(session, job_id)
        project.duration_seconds = probe.duration_seconds
        project.status = "completed"
        # Usage is recorded only for original processing (the Gemini call);
        # re-renders reuse saved captions and cost no transcription.
        session.add(Usage(user_id=project.user_id, duration_processed_seconds=probe.duration_seconds))
        diagnostics["caption_completion"] = {
            "total_seconds": round(time.perf_counter() - finalize_started, 6),
        }
        _update_job(session, job, status=JobStatus.completed,
                    stage="Captions ready", progress=100)
        _save_diagnostics(session, job, diagnostics)
        logger.info(
            "caption_completion job=%s total_s=%.3f",
            job_id, time.perf_counter() - finalize_started,
        )

    except JobCancelled:
        _save_diagnostics(session, job, diagnostics)
        _update_job(session, job, status=JobStatus.cancelled, stage="Cancelled")
    except ValueError as e:
        # Expected/validation-style errors -> safe to show the message directly.
        _save_diagnostics(session, job, diagnostics)
        _update_job(session, job, status=JobStatus.failed, stage="Failed", error=str(e))
    except Exception:
        # Keep the user-facing error generic while preserving the traceback in
        # worker logs for diagnosis.
        logger.exception("Video processing failed for job %s", job_id)
        _save_diagnostics(session, job, diagnostics)
        _update_job(
            session, job, status=JobStatus.failed, stage="Failed",
            error="We couldn't process this video right now. Please try again.",
        )
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
        session.close()


@task(bind=True, name="workers.tasks.rerender_project_job")
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
    diagnostics = {
        "schema_version": 1,
        "job_type": "edited_rerender",
        "pipeline_phases_seconds": {},
    }

    try:
        if caption is None:
            raise ValueError("No captions found for this project yet.")

        _check_cancelled(session, job_id)
        job.celery_task_id = self.request.id
        _update_job(session, job, status=JobStatus.preparing, stage="Preparing video", progress=10)
        _check_cancelled(session, job_id)
        local_video_path = work_dir / "source.mp4"
        phase_started = time.perf_counter()
        storage_service.download_file(video.storage_key, local_video_path)
        diagnostics["pipeline_phases_seconds"]["source_download"] = round(time.perf_counter() - phase_started, 6)
        phase_started = time.perf_counter()
        probe = ffmpeg_service.probe_video(local_video_path)
        diagnostics["pipeline_phases_seconds"]["input_probe"] = round(time.perf_counter() - phase_started, 6)
        diagnostics["source"] = {
            "bytes": local_video_path.stat().st_size,
            "width": probe.width,
            "height": probe.height,
            "duration_seconds": probe.duration_seconds,
            "has_audio": probe.has_audio,
            "container": probe.mime_guess,
            "video_codec": probe.video_codec,
            "frame_rate": probe.frame_rate,
            "pixel_format": probe.pixel_format,
            "bit_rate": probe.bit_rate,
            "audio_codec": probe.audio_codec,
        }

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
        render_metrics = {}
        flutter_render_service.render_scene(
            local_video_path, snapshot, out_path, quality=quality, progress=on_progress,
            probe=probe, metrics=render_metrics)
        diagnostics["render"] = render_metrics
        _save_diagnostics(session, job, diagnostics)
        finalize_started = time.perf_counter()
        stage_started = time.perf_counter()
        _update_job(session, job, status=JobStatus.finalizing, stage="Finalizing", progress=92)
        stage_transition_seconds = time.perf_counter() - stage_started
        _check_cancelled(session, job_id)
        export_key = f"exports/{project.id}/{job.id}.mp4"
        upload_started = time.perf_counter()
        storage_service.upload_file(out_path, export_key)
        upload_seconds = time.perf_counter() - upload_started
        session.add(Export(project_id=project.id, storage_key=export_key, quality=quality, render_fingerprint=fingerprint(snapshot), job_id=job.id))
        project.status = "completed"
        commit_started = time.perf_counter()
        _update_job(session, job, status=JobStatus.completed, stage="Completed", progress=100)
        commit_seconds = time.perf_counter() - commit_started
        diagnostics["finalization"] = {
            "stage_transition_seconds": round(stage_transition_seconds, 6),
            "storage_upload_seconds": round(upload_seconds, 6),
            "database_completion_commit_seconds": round(commit_seconds, 6),
            "total_seconds": round(time.perf_counter() - finalize_started, 6),
            "output_bytes": out_path.stat().st_size,
        }
        _save_diagnostics(session, job, diagnostics)
        logger.info(
            "finalize_timing job=%s upload_s=%.3f output_bytes=%d database_commit_s=%.3f total_s=%.3f",
            job_id, upload_seconds, out_path.stat().st_size,
            commit_seconds, time.perf_counter() - finalize_started,
        )

    except JobCancelled:
        _save_diagnostics(session, job, diagnostics)
        _update_job(session, job, status=JobStatus.cancelled, stage="Cancelled")
    except ValueError as e:
        _save_diagnostics(session, job, diagnostics)
        _update_job(session, job, status=JobStatus.failed, stage="Failed", error=str(e))
    except Exception:
        logger.exception("Video re-render failed for job %s", job_id)
        _save_diagnostics(session, job, diagnostics)
        _update_job(
            session, job, status=JobStatus.failed, stage="Failed",
            error="We couldn't re-render this video right now. Please try again.",
        )
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
        session.close()


@task(name="workers.tasks.cleanup_expired_files")
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
            if settings.chunk_storage_backend == "object_storage":
                if s.updated_at.timestamp() < cutoff:
                    from services.chunked_upload_service import cleanup_session
                    cleanup_session(s.id)
                    s.status = "cancelled"
            elif not (Path(settings.temp_storage_dir) / "uploads" / s.id).exists() and s.updated_at.timestamp() < cutoff:
                s.status = "cancelled"
        session.commit()
    finally:
        session.close()


def recover_orphaned_jobs() -> None:
    """Called once on backend startup (section 58). Any job still marked as
    an in-progress status when the process starts means a previous worker
    crashed mid-job -- those files are gone, so we fail them cleanly rather
    than leaving them stuck in 'processing' forever."""
    # An API container starting says nothing about separate Modal workers.
    if settings.job_backend == "modal":
        return
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
