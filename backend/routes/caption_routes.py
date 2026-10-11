from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.security import get_current_user_id
from models.models import Caption, Project, ProcessingJob, JobStatus, Export
from services.render_scene import caption_snapshot, fingerprint
from schemas.schemas import (
    CaptionTranslateRequest, CaptionUpdateRequest, GeminiTranscriptResponse,
    RenderRequest, VideoUploadResponse,
)
from workers.tasks import rerender_project_job
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

    aspect_ratio = payload.aspect_ratio if payload else caption.aspect_ratio
    caption.aspect_ratio = aspect_ratio
    job = ProcessingJob(project_id=project.id, status=JobStatus.queued, stage="Queued", progress=0,
                        render_snapshot=caption_snapshot(caption, aspect_ratio))
    db.add(job)
    project.status = "processing"
    await db.commit()
    await db.refresh(job)

    rerender_project_job.delay(
        job.id,
        (payload.quality if payload else "standard"),
        (payload.aspect_ratio if payload else "original"),
    )
    return VideoUploadResponse(project_id=project.id, job_id=job.id)
