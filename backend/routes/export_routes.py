import re

import aiofiles
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.config import get_settings
from app.security import get_current_user_id
from models.models import Export, Project
from services import storage_service

router = APIRouter(tags=["exports"])
_DOWNLOAD_BLOCK_SIZE = 1024 * 1024


@router.get("/api/projects/{project_id}/exports")
async def list_exports(project_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    project = await db.get(Project, project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Project not found.")
    exports = (await db.scalars(
        select(Export).where(Export.project_id == project_id).order_by(Export.created_at.desc())
    )).all()
    return [
        {"id": e.id, "quality": e.quality, "created_at": e.created_at.isoformat(),
         "job_id": e.job_id, "render_fingerprint": e.render_fingerprint,
         "output_resolution": e.output_resolution, "output_fps": e.output_fps}
        for e in exports
    ]


@router.get("/api/exports/{export_id}/download")
async def download_export(export_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    export = await db.get(Export, export_id)
    if not export:
        raise HTTPException(status_code=404, detail="Export not found.")
    project = await db.get(Project, export.project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Export not found.")

    # Never a public URL (section 19/20) -- short-lived signed link only,
    # generated fresh on every request rather than stored.
    safe_name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", project.name).strip()
    if not safe_name:
        safe_name = "captioned-video"
    if not safe_name.lower().endswith(".mp4"):
        safe_name += ".mp4"

    url = storage_service.signed_download_url(
        export.storage_key,
        expires_seconds=3600,
        download=True,
        download_filename=safe_name,
    )
    return {"download_url": url, "expires_in_seconds": 3600}


@router.get("/api/exports/{export_id}/content")
async def stream_export_content(
    export_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Stream an owned export through the API for same-origin browser measurement."""
    export = await db.get(Export, export_id)
    if not export:
        raise HTTPException(status_code=404, detail="Export not found.")
    project = await db.get(Project, export.project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Export not found.")

    settings = get_settings()
    if settings.storage_provider == "modal":
        path = await storage_service.snapshot_modal_file(export.storage_key)
        if path is None:
            raise HTTPException(status_code=404, detail="Export file not found.")
        size = path.stat().st_size

        async def chunks():
            try:
                async with aiofiles.open(path, "rb") as source:
                    while block := await source.read(_DOWNLOAD_BLOCK_SIZE):
                        yield block
            finally:
                path.unlink(missing_ok=True)

    else:
        try:
            obj = storage_service._client().get_object(
                Bucket=settings.storage_bucket,
                Key=export.storage_key,
            )
        except Exception as exc:
            raise HTTPException(status_code=404, detail="Export file not found.") from exc
        body = obj["Body"]
        size = obj.get("ContentLength")

        def chunks():
            try:
                while block := body.read(_DOWNLOAD_BLOCK_SIZE):
                    yield block
            finally:
                body.close()

    headers = {"Accept-Ranges": "none", "Cache-Control": "private, no-store"}
    if size is not None:
        headers["Content-Length"] = str(size)
    return StreamingResponse(chunks(), media_type="video/mp4", headers=headers)
