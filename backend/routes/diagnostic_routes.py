"""Authenticated, read-only diagnostics for external services and render profiling."""

import asyncio
import os
import shutil
import tempfile
import httpx
import boto3
from fastapi import APIRouter, Depends, HTTPException
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
from botocore.client import Config

from app.config import get_settings
from app.database import get_db
from app.security import get_current_user_id
from models.models import ProcessingJob, Project
from workers.celery_app import celery_app

router = APIRouter(prefix="/api/diagnostics", tags=["diagnostics"])


def _require_development() -> None:
    if get_settings().environment != "development":
        raise HTTPException(status_code=404, detail="Not found")


def _check(name: str, status: str, detail: str) -> dict[str, str]:
    return {"name": name, "status": status, "detail": detail}


@router.get("/system")
async def get_system_diagnostics(
    _user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
) -> dict:
    """Check production dependencies without exposing secrets or changing state."""
    settings = get_settings()
    checks: list[dict[str, str]] = []

    try:
        await db.execute(text("SELECT 1"))
        checks.append(_check("Database", "ok", "Connected and responding."))
    except Exception:
        checks.append(_check("Database", "error", "Could not connect to the database."))

    redis_client = None
    redis_ok = False
    try:
        redis_client = Redis.from_url(
            settings.celery_broker_url,
            socket_connect_timeout=3,
            socket_timeout=3,
        )
        await redis_client.ping()
        redis_ok = True
        checks.append(_check("Redis broker", "ok", "Connected and responding."))
    except Exception:
        checks.append(_check("Redis broker", "error", "Cannot reach the configured Celery broker."))
    finally:
        if redis_client is not None:
            await redis_client.aclose()

    if redis_ok:
        try:
            replies = await asyncio.to_thread(celery_app.control.ping, timeout=2)
            count = len(replies or [])
            checks.append(
                _check("Celery worker", "ok" if count else "error",
                       f"{count} worker(s) responding." if count else "No Celery workers are responding.")
            )
        except Exception:
            checks.append(_check("Celery worker", "error", "Could not contact a Celery worker."))
    else:
        checks.append(_check("Celery worker", "blocked", "Cannot check workers until Redis is available."))

    storage_configured = bool(
        settings.storage_bucket and settings.storage_access_key and settings.storage_secret_key
    )
    if storage_configured:
        def check_bucket() -> None:
            client = boto3.client(
                "s3",
                region_name=settings.storage_region,
                endpoint_url=settings.storage_endpoint_url or None,
                aws_access_key_id=settings.storage_access_key,
                aws_secret_access_key=settings.storage_secret_key,
                config=Config(
                    signature_version="s3v4",
                    connect_timeout=3,
                    read_timeout=3,
                    retries={"max_attempts": 1},
                ),
            )
            client.head_bucket(Bucket=settings.storage_bucket)

        try:
            await asyncio.to_thread(check_bucket)
            checks.append(_check("Video storage", "ok", "Bucket is reachable."))
        except Exception:
            checks.append(_check("Video storage", "error", "Bucket is not reachable with the current settings."))
    else:
        checks.append(_check("Video storage", "error", "Storage credentials or bucket are not configured."))

    ffmpeg_installed = shutil.which("ffmpeg") is not None
    checks.append(
        _check(
            "FFmpeg",
            "ok" if ffmpeg_installed else "error",
            "Installed." if ffmpeg_installed else "Not found in the backend container.",
        )
    )

    try:
        os.makedirs(settings.temp_storage_dir, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=settings.temp_storage_dir, delete=True):
            pass
        checks.append(_check("Temporary disk", "ok", "Writable."))
    except Exception:
        checks.append(_check("Temporary disk", "error", "Configured temporary directory is not writable."))

    # Linux cgroup memory is the container limit; do not expose paths or env values.
    try:
        with open("/sys/fs/cgroup/memory.current", encoding="utf-8") as current_file:
            used = int(current_file.read().strip())
        with open("/sys/fs/cgroup/memory.max", encoding="utf-8") as limit_file:
            raw_limit = limit_file.read().strip()
        if raw_limit != "max":
            limit = int(raw_limit)
            percent = round(used * 100 / limit)
            status = "warning" if percent >= 85 else "ok"
            checks.append(_check("Container memory", status, f"{percent}% of the container memory limit is in use."))
    except (OSError, ValueError):
        pass

    return {"checks": checks}


@router.get("/gemini")
async def test_gemini() -> dict:
    settings = get_settings()
    _require_development()

    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        f"{settings.gemini_model}:generateContent"
    )
    payload = {"contents": [{"parts": [{"text": "Reply with exactly OK"}]}]}

    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            url,
            headers={"x-goog-api-key": settings.gemini_api_key},
            json=payload,
        )

    try:
        body = response.json()
    except ValueError:
        body = {}

    error = body.get("error", {}) if isinstance(body, dict) else {}
    text = ""
    if response.is_success:
        candidates = body.get("candidates", [])
        if candidates:
            text = candidates[0].get("content", {}).get("parts", [{}])[0].get("text", "")

    return {
        "ok": response.is_success,
        "http_status": response.status_code,
        "model": settings.gemini_model,
        "api_key_configured": bool(settings.gemini_api_key),
        "response_text": text,
        "error": error.get("message", "") if isinstance(error, dict) else "",
    }


@router.get("/jobs/{job_id}/render")
async def get_render_diagnostics(
    job_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
) -> dict:
    """Return detailed timing only for a development user's own render job."""
    _require_development()
    job = await db.get(ProcessingJob, job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found.")
    project = await db.get(Project, job.project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Job not found.")
    return {
        "job_id": job.id,
        "project_id": job.project_id,
        "status": job.status.value if hasattr(job.status, "value") else str(job.status),
        "diagnostics": job.render_diagnostics or {},
    }
