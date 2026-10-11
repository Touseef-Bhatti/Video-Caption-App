"""
Direct (single-request) upload endpoint -- the simple path, best suited
to smaller files on a stable connection. For large files or unreliable
networks, routes/chunked_upload_routes.py provides a resumable path; both
funnel into services.upload_finalize_service.finalize_upload so they share
one set of validation/DB rules.
"""
import uuid
from pathlib import Path

import aiofiles
from fastapi import APIRouter, Depends, HTTPException, Request, UploadFile, File, Form
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.security import get_current_user_id
from app.config import get_settings
from app.limiter import limiter
from models.models import Project, Video
from schemas.schemas import VideoUploadResponse
from services import storage_service
from services.upload_finalize_service import finalize_upload, UploadValidationError

router = APIRouter(prefix="/api/videos", tags=["videos"])
projects_router = APIRouter(prefix="/api/projects", tags=["videos"])
settings = get_settings()


@projects_router.get("/{project_id}/video/preview-url")
async def get_video_preview_url(project_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    """A short-lived signed URL to the ORIGINAL uploaded video (no captions
    burned in), used by the caption editor and preview screens to play the
    source video client-side with captions overlaid as text -- not the
    final rendered export. Never a public URL (section 19, 20)."""
    project = await db.get(Project, project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Project not found.")
    video = await db.scalar(select(Video).where(Video.project_id == project_id))
    if not video:
        raise HTTPException(status_code=404, detail="No video uploaded for this project yet.")
    url = storage_service.signed_download_url(video.storage_key, expires_seconds=1800)
    return {"preview_url": url, "expires_in_seconds": 1800, "width": video.width, "height": video.height}


@router.post("/upload", response_model=VideoUploadResponse, status_code=201)
@limiter.limit(f"{settings.rate_limit_upload_per_hour}/hour")
async def upload_video(
    request: Request,
    file: UploadFile = File(...),
    project_name: str = Form(...),
    caption_language: str = Form("auto"),
    translate_to: str | None = Form(None),
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Best for files that comfortably fit in one request on a stable
    connection. For a 1-hour video on a flaky network, prefer
    POST /api/uploads/init (chunked_upload_routes) instead -- this endpoint
    has no resume capability: a dropped connection mid-upload means
    starting over."""
    if file.content_type not in settings.allowed_mime_list:
        raise HTTPException(status_code=415, detail="Unsupported video format. Please upload MP4, MOV, MKV, or WEBM.")

    # Staging filename is entirely server-generated -- never built from the
    # client-supplied filename, even sanitized (path-traversal protection,
    # section 54). The real, user-visible filename is preserved separately
    # and only used as metadata (Project.original_filename).
    upload_dir = Path(settings.temp_storage_dir) / "uploads" / "_direct"
    upload_dir.mkdir(parents=True, exist_ok=True)
    local_path = upload_dir / f"{uuid.uuid4()}.tmp"

    size_bytes = 0
    max_bytes = settings.max_upload_size_mb * 1024 * 1024
    async with aiofiles.open(local_path, "wb") as out:
        while chunk := await file.read(1024 * 1024):
            size_bytes += len(chunk)
            if size_bytes > max_bytes:
                await out.close()
                local_path.unlink(missing_ok=True)
                raise HTTPException(
                    status_code=413,
                    detail=f"File is too large. Maximum upload size is {settings.max_upload_size_mb} MB.",
                )
            await out.write(chunk)

    try:
        project_id, job_id = await finalize_upload(
            local_path=local_path,
            declared_mime=file.content_type,
            original_filename=file.filename or "video.mp4",
            project_name=project_name,
            caption_language=caption_language,
            translate_to=translate_to,
            size_bytes=size_bytes,
            user_id=user_id,
            db=db,
        )
    except UploadValidationError as e:
        raise HTTPException(status_code=422, detail=str(e))

    return VideoUploadResponse(project_id=project_id, job_id=job_id)
