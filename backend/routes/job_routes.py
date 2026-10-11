from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.security import get_current_user_id
from models.models import ProcessingJob, Project, JobStatus
from schemas.schemas import JobStatusResponse
from workers.celery_app import celery_app

router = APIRouter(prefix="/api/jobs", tags=["jobs"])
projects_router = APIRouter(prefix="/api/projects", tags=["jobs"])


async def _get_owned_job(job_id: str, user_id: str, db: AsyncSession) -> ProcessingJob:
    job = await db.get(ProcessingJob, job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found.")
    project = await db.get(Project, job.project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Job not found.")
    return job


@router.get("/{job_id}", response_model=JobStatusResponse)
async def get_job(job_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    job = await _get_owned_job(job_id, user_id, db)
    return JobStatusResponse(
        id=job.id, project_id=job.project_id, status=job.status, stage=job.stage,
        progress=job.progress, error=job.error, created_at=job.created_at,
    )


@router.post("/{job_id}/cancel", response_model=JobStatusResponse)
async def cancel_job(job_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    job = await _get_owned_job(job_id, user_id, db)
    if job.status in (JobStatus.completed, JobStatus.failed, JobStatus.cancelled):
        raise HTTPException(status_code=400, detail="This job has already finished and can't be cancelled.")

    # Revoke the Celery task if it's already dispatched to a worker. The
    # worker-side task also checks job.status itself at each stage boundary
    # (_check_cancelled in workers/tasks.py) so cancellation is honored even
    # if the revoke signal arrives mid-step rather than between steps.
    if job.celery_task_id:
        celery_app.control.revoke(job.celery_task_id, terminate=True)

    job.status = JobStatus.cancelled
    job.stage = "Cancelled"
    await db.commit()
    return JobStatusResponse(
        id=job.id, project_id=job.project_id, status=job.status, stage=job.stage,
        progress=job.progress, error=job.error, created_at=job.created_at,
    )


@projects_router.get("/{project_id}/jobs/latest", response_model=JobStatusResponse)
async def get_latest_job_for_project(project_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    """Dashboard fix: a project alone doesn't tell the client which job to
    poll for progress, since a project can have had several jobs (original
    processing + any re-renders). Always returns the most recently created
    one so 'resume watching progress' has somewhere to point."""
    project = await db.get(Project, project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Project not found.")
    job = await db.scalar(
        select(ProcessingJob).where(ProcessingJob.project_id == project_id).order_by(ProcessingJob.created_at.desc())
    )
    if not job:
        raise HTTPException(status_code=404, detail="No jobs found for this project yet.")
    return JobStatusResponse(
        id=job.id, project_id=job.project_id, status=job.status, stage=job.stage,
        progress=job.progress, error=job.error, created_at=job.created_at,
    )
