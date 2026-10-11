import re

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.security import get_current_user_id
from models.models import Export, Project
from services import storage_service

router = APIRouter(tags=["exports"])


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
         "job_id": e.job_id, "render_fingerprint": e.render_fingerprint}
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
