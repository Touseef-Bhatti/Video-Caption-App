from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.security import get_current_user_id
from models.models import Project, Video
from services import storage_service

router = APIRouter(prefix="/api/projects", tags=["projects"])


@router.get("")
async def list_projects(user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    projects = (await db.scalars(
        select(Project).where(Project.user_id == user_id).order_by(Project.created_at.desc())
    )).all()
    return [
        {
            "id": p.id,
            "name": p.name,
            "status": p.status,
            "duration_seconds": p.duration_seconds,
            "created_at": p.created_at.isoformat(),
        }
        for p in projects
    ]


@router.get("/{project_id}")
async def get_project(project_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    project = await db.get(Project, project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Project not found.")
    return {
        "id": project.id,
        "name": project.name,
        "status": project.status,
        "duration_seconds": project.duration_seconds,
        "created_at": project.created_at.isoformat(),
    }


@router.delete("/{project_id}", status_code=204)
async def delete_project(project_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    project = await db.get(Project, project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Project not found.")

    video = await db.scalar(select(Video).where(Video.project_id == project_id))
    if video:
        storage_service.delete_file(video.storage_key)

    await db.delete(project)  # cascades to Video/ProcessingJob/Caption/Export via FK ondelete="CASCADE"
    await db.commit()
