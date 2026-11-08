"""Development-only diagnostics for external services and render profiling."""

import httpx
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.database import get_db
from app.security import get_current_user_id
from models.models import ProcessingJob, Project

router = APIRouter(prefix="/api/diagnostics", tags=["diagnostics"])


def _require_development() -> None:
    if get_settings().environment != "development":
        raise HTTPException(status_code=404, detail="Not found")


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
