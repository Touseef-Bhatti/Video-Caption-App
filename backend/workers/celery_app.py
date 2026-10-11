from celery import Celery
from app.config import get_settings

settings = get_settings()

celery_app = Celery(
    "caption_app",
    broker=settings.celery_broker_url,
    backend=settings.celery_result_backend,
    include=["workers.tasks"],
)

celery_app.conf.update(
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    task_track_started=True,
    task_acks_late=True,            # redeliver a task if the worker dies mid-job
    worker_prefetch_multiplier=1,    # don't hoard long-running video jobs
    task_time_limit=60 * 60 * 2,     # hard cap: 2 hours per job
    task_soft_time_limit=60 * 60 * 2 - 60,
    broker_connection_retry_on_startup=True,
    beat_schedule={
        # Runs workers.tasks.cleanup_expired_files on a timer (section
        # 18/59) -- sweeps stale processing temp files, abandoned upload
        # chunk directories, and marks orphaned upload_sessions as
        # cancelled. Interval is configurable via CLEANUP_INTERVAL_MINUTES
        # rather than hardcoded, since it should track TEMP_FILE_RETENTION_MINUTES.
        "cleanup-expired-files": {
            "task": "workers.tasks.cleanup_expired_files",
            "schedule": settings.cleanup_interval_minutes * 60,
        },
    },
)
