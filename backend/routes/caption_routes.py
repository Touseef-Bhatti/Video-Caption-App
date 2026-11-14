import asyncio
import logging

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.security import get_current_user_id
from models.models import Caption, Project, ProcessingJob, JobStatus, Export
from services.render_scene import caption_snapshot, fingerprint
from schemas.schemas import (
    CaptionScriptRequest, CaptionTranslateRequest, CaptionUpdateRequest, GeminiTranscriptResponse,
    RenderRequest, VideoUploadResponse,
)
from workers.tasks import rerender_project_job
from workers.task_queue import cancel_task, submit_job
from services.template_catalog import validate_caption_configuration
from services import gemini_service

router = APIRouter(prefix="/api/projects", tags=["captions"])


async def _get_owned_project(project_id: str, user_id: str, db: AsyncSession) -> Project:
    project = await db.get(Project, project_id)
    if not project or project.user_id != user_id:
        raise HTTPException(status_code=404, detail="Project not found.")
    return project


@router.get("/{project_id}/captions")
async def get_captions(project_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    await _get_owned_project(project_id, user_id, db)
    caption = await db.scalar(select(Caption).where(Caption.project_id == project_id))
    if not caption:
        raise HTTPException(status_code=404, detail="No captions found for this project yet.")
    current_fingerprint = fingerprint(caption_snapshot(caption))
    matching_export = await db.scalar(select(Export).where(
        Export.project_id == project_id, Export.render_fingerprint == current_fingerprint
    ).order_by(Export.created_at.desc()))
    return {
        "id": caption.id,
        "language": caption.language,
        "style_preset": caption.style_preset,
        "style_overrides": caption.style_overrides,
        "caption_data": caption.caption_data,
        "aspect_ratio": caption.aspect_ratio,
        "render_fingerprint": current_fingerprint,
        "matching_export_id": matching_export.id if matching_export else None,
    }


@router.post("/{project_id}/captions/translate")
async def translate_captions(
    project_id: str, payload: CaptionTranslateRequest,
    user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db),
):
    await _get_owned_project(project_id, user_id, db)
    caption = await db.scalar(select(Caption).where(Caption.project_id == project_id))
    if not caption:
        raise HTTPException(status_code=404, detail="No captions found for this project yet.")
    try:
        transcript = GeminiTranscriptResponse.model_validate(payload.caption_data)
    except Exception as exc:
        raise HTTPException(status_code=422, detail="Caption data is invalid.") from exc
    try:
        translated = await gemini_service.translate_transcript(transcript, payload.target_language.strip())
    except Exception as exc:
        raise HTTPException(status_code=502, detail="Gemini could not generate captions in that language. Please try again.") from exc
    return {"caption_data": translated.model_dump()}


@router.post("/{project_id}/captions/script")
async def change_caption_script(
    project_id: str, payload: CaptionScriptRequest,
    user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db),
):
    await _get_owned_project(project_id, user_id, db)
    caption = await db.scalar(select(Caption).where(Caption.project_id == project_id))
    if not caption:
        raise HTTPException(status_code=404, detail="No captions found for this project yet.")
    try:
        transcript = GeminiTranscriptResponse.model_validate(payload.caption_data)
    except Exception as exc:
        raise HTTPException(status_code=422, detail="Caption data is invalid.") from exc
    try:
        converted = await gemini_service.change_transcript_script(
            transcript, payload.target_script
        )
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail="Could not change the caption text script. Please try again.",
        ) from exc
    return {"caption_data": converted.model_dump()}


@router.put("/{project_id}/captions")
async def update_captions(
    project_id: str, payload: CaptionUpdateRequest,
    user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db),
):
    await _get_owned_project(project_id, user_id, db)
    caption = await db.scalar(select(Caption).where(Caption.project_id == project_id))
    if not caption:
        raise HTTPException(status_code=404, detail="No captions found for this project yet.")

    template_id = payload.style_preset or caption.style_preset
    caption_data = payload.caption_data if payload.caption_data is not None else caption.caption_data
    style_overrides = (
        payload.style_overrides.model_dump(exclude_none=True)
        if payload.style_overrides is not None else caption.style_overrides or {}
    )
    try:
        template_id, caption_data, style_overrides = validate_caption_configuration(
            template_id, caption_data, style_overrides
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    caption.caption_data = caption_data
    caption.language = str(caption_data.get("language", caption.language))
    caption.style_preset = template_id
    caption.style_overrides = style_overrides
    if payload.aspect_ratio is not None:
        caption.aspect_ratio = payload.aspect_ratio

    await db.commit()
    return {"detail": "Captions updated.", "render_fingerprint": fingerprint(caption_snapshot(caption))}


@router.post("/{project_id}/render", response_model=VideoUploadResponse, status_code=201)
async def trigger_render(
    project_id: str,
    payload: RenderRequest | None = None,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """Re-renders the final video from the currently saved caption text/style
    -- never calls Gemini again (section 56), so editing captions and
    re-exporting is fast and free of extra AI cost."""
    project = await _get_owned_project(project_id, user_id, db)
    caption = await db.scalar(select(Caption).where(Caption.project_id == project_id))
    if not caption:
        raise HTTPException(status_code=404, detail="No captions found for this project yet. Upload a video first.")

    try:
        template_id, caption_data, style_overrides = validate_caption_configuration(
            caption.style_preset, caption.caption_data, caption.style_overrides or {}
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    caption.style_preset = template_id
    caption.caption_data = caption_data
    caption.style_overrides = style_overrides

    aspect_ratio = (payload.aspect_ratio if payload and payload.aspect_ratio
                    else caption.aspect_ratio)
    caption.aspect_ratio = aspect_ratio
    quality = payload.quality if payload else "standard"
    snapshot = caption_snapshot(caption, aspect_ratio)
    snapshot_fingerprint = fingerprint(snapshot)
    output_resolution = payload.output_resolution if payload else 0
    output_fps = payload.output_fps if payload else 0
    output_options = {
        "quality": quality,
        "output_resolution": output_resolution,
        "output_fps": output_fps,
    }

    # Reuse finished output before applying the active-render quota. This lets
    # users download a cached format without consuming another render slot.
    existing_export = await db.scalar(
        select(Export).where(
            Export.project_id == project.id,
            Export.render_fingerprint == snapshot_fingerprint,
            Export.quality == quality,
            Export.output_resolution == output_resolution,
            Export.output_fps == output_fps,
            Export.job_id.is_not(None),
        ).order_by(Export.created_at.desc())
    )
    if existing_export:
        existing_job = await db.get(ProcessingJob, existing_export.job_id)
        if existing_job and existing_job.status == JobStatus.completed:
            return VideoUploadResponse(project_id=project.id, job_id=existing_job.id)

    # Keep one active render per user. Repeated requests for the same profile
    # attach to the existing job; a different request replaces it.
    active_job = await db.scalar(
        select(ProcessingJob)
        .join(Project, ProcessingJob.project_id == Project.id)
        .where(
            Project.user_id == user_id,
            ProcessingJob.render_snapshot.is_not(None),
            ProcessingJob.status.in_([
                JobStatus.queued, JobStatus.preparing,
                JobStatus.rendering, JobStatus.finalizing,
            ]),
        )
        .order_by(ProcessingJob.created_at.desc())
    )
    if active_job:
        active_options = (active_job.render_snapshot or {}).get("export_options")
        same_request = (
            active_job.project_id == project.id
            and active_options == output_options
            and fingerprint({key: value for key, value in (active_job.render_snapshot or {}).items()
                             if key != "export_options"}) == snapshot_fingerprint
        )
        if same_request:
            return VideoUploadResponse(project_id=project.id, job_id=active_job.id)

        # Persist cancellation first so the worker's cooperative checks stop
        # it even if the scheduler call is briefly unavailable.
        active_job.status = JobStatus.cancelled
        active_job.stage = "Replaced by a newer render"
        await db.commit()
        if active_job.celery_task_id:
            try:
                await asyncio.to_thread(cancel_task, active_job.celery_task_id)
            except Exception as exc:
                logging.getLogger(__name__).exception(
                    "Could not stop replaced render %s", active_job.id
                )
                raise HTTPException(
                    status_code=503,
                    detail="The previous render could not be stopped yet. Please try again shortly.",
                ) from exc

    render_snapshot = {
        **snapshot,
        "export_options": output_options,
    }
    job = ProcessingJob(project_id=project.id, status=JobStatus.queued, stage="Queued", progress=0,
                        render_snapshot=render_snapshot)
    db.add(job)
    project.status = "processing"
    await db.commit()
    await db.refresh(job)

    render_arguments = [quality, aspect_ratio]
    if output_resolution != 0 or output_fps != 0:
        render_arguments.extend([output_resolution, output_fps])
    await submit_job(rerender_project_job, job, db, *render_arguments)
    return VideoUploadResponse(project_id=project.id, job_id=job.id)
