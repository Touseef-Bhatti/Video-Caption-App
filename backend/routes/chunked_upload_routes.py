"""
Resumable upload flow:

  POST   /api/uploads/init                  -> {upload_id, chunk_size, total_chunks}
  PUT    /api/uploads/{id}/chunks/{index}    -> upload (or re-upload) one chunk
  GET    /api/uploads/{id}/status            -> which chunk indices have arrived
  POST   /api/uploads/{id}/complete          -> assemble + validate + enqueue processing
  DELETE /api/uploads/{id}                   -> cancel, delete partial chunks

The client is expected to: call init once, PUT each chunk (any order,
retry freely -- a repeated index just overwrites the same chunk file), and
on reconnect after a dropped connection, call GET status first to find out
which indices already landed so it only re-sends what's missing, rather
than restarting the whole upload.
"""
import math

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.security import get_current_user_id
from app.config import get_settings
from app.limiter import limiter
from models.models import UploadSession
from schemas.schemas import VideoUploadResponse
from services import chunked_upload_service as chunks
from services.upload_finalize_service import finalize_upload, UploadValidationError

router = APIRouter(prefix="/api/uploads", tags=["uploads"])
settings = get_settings()


class InitUploadRequest(BaseModel):
    file_name: str
    content_type: str
    total_size_bytes: int = Field(gt=0)
    project_name: str
    caption_language: str = Field(default="auto", min_length=2, max_length=100)
    translate_to: str | None = Field(default=None, min_length=2, max_length=100)
    chunk_size_bytes: int = Field(default=chunks.DEFAULT_CHUNK_SIZE_BYTES, ge=1024 * 1024, le=50 * 1024 * 1024)


class InitUploadResponse(BaseModel):
    upload_id: str
    chunk_size_bytes: int
    total_chunks: int


class UploadStatusResponse(BaseModel):
    upload_id: str
    total_chunks: int
    received_chunks: list[int]
    completed: bool


async def _get_owned_session(upload_id: str, user_id: str, db: AsyncSession) -> UploadSession:
    session = await db.get(UploadSession, upload_id)
    if not session or session.user_id != user_id:
        raise HTTPException(status_code=404, detail="Upload session not found.")
    return session


@router.post("/init", response_model=InitUploadResponse, status_code=201)
@limiter.limit(f"{settings.rate_limit_upload_per_hour}/hour")
async def init_upload(request: Request, payload: InitUploadRequest, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    if payload.content_type not in settings.allowed_mime_list:
        raise HTTPException(status_code=415, detail="Unsupported video format. Please upload MP4, MOV, MKV, or WEBM.")
    max_bytes = settings.max_upload_size_mb * 1024 * 1024
    if payload.total_size_bytes > max_bytes:
        raise HTTPException(status_code=413, detail=f"File is too large. Maximum upload size is {settings.max_upload_size_mb} MB.")

    total_chunks = math.ceil(payload.total_size_bytes / payload.chunk_size_bytes)
    session = UploadSession(
        user_id=user_id,
        project_name=payload.project_name,
        caption_language=payload.caption_language,
        translate_to=payload.translate_to,
        original_filename=payload.file_name,
        mime_type=payload.content_type,
        total_size_bytes=payload.total_size_bytes,
        chunk_size_bytes=payload.chunk_size_bytes,
        total_chunks=total_chunks,
        status="uploading",
    )
    db.add(session)
    await db.commit()
    return InitUploadResponse(upload_id=session.id, chunk_size_bytes=payload.chunk_size_bytes, total_chunks=total_chunks)


@router.put("/{upload_id}/chunks/{chunk_index}")
async def upload_chunk(
    upload_id: str, chunk_index: int, request: Request,
    user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db),
):
    session = await _get_owned_session(upload_id, user_id, db)
    if session.status != "uploading":
        raise HTTPException(status_code=400, detail="This upload has already been completed or cancelled.")
    if chunk_index < 0 or chunk_index >= session.total_chunks:
        raise HTTPException(status_code=400, detail="Invalid chunk index for this upload.")

    chunk_dir = chunks.session_dir(upload_id)
    chunk_dir.mkdir(parents=True, exist_ok=True)
    path = chunks.chunk_path(upload_id, chunk_index)
    tmp_path = path.with_suffix(".part")

    # A chunk may legitimately be smaller than chunk_size_bytes only if it's
    # the LAST chunk -- every other chunk must be exactly chunk_size_bytes.
    # Enforced while streaming so a misbehaving/malicious client can't send
    # an oversized "chunk" and quietly exceed the total size limit.
    is_last_chunk = chunk_index == session.total_chunks - 1
    max_this_chunk = session.chunk_size_bytes
    received = 0
    with open(tmp_path, "wb") as out:
        async for piece in request.stream():
            received += len(piece)
            if received > max_this_chunk:
                out.close()
                tmp_path.unlink(missing_ok=True)
                raise HTTPException(status_code=413, detail="This chunk is larger than the agreed chunk size.")
            out.write(piece)

    if not is_last_chunk and received != session.chunk_size_bytes:
        tmp_path.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail="Chunk size doesn't match the agreed chunk size.")
    if received == 0:
        tmp_path.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail="Received an empty chunk.")

    tmp_path.replace(path)  # atomic on the same filesystem -- a retry overwrites cleanly, never a partial file
    return {"chunk_index": chunk_index, "received_bytes": received}


@router.get("/{upload_id}/status", response_model=UploadStatusResponse)
async def get_upload_status(upload_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    session = await _get_owned_session(upload_id, user_id, db)
    received = sorted(chunks.received_chunk_indices(upload_id, session.total_chunks))
    return UploadStatusResponse(
        upload_id=upload_id, total_chunks=session.total_chunks,
        received_chunks=received, completed=session.status == "completed",
    )


@router.post("/{upload_id}/complete", response_model=VideoUploadResponse, status_code=201)
async def complete_upload(upload_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    session = await _get_owned_session(upload_id, user_id, db)
    if session.status == "completed":
        raise HTTPException(status_code=400, detail="This upload has already been completed.")

    received = chunks.received_chunk_indices(upload_id, session.total_chunks)
    missing = [i for i in range(session.total_chunks) if i not in received]
    if missing:
        raise HTTPException(
            status_code=400,
            detail=f"{len(missing)} of {session.total_chunks} chunks are still missing. Resend them before completing.",
        )

    assembled_path = chunks.session_dir(upload_id) / "assembled.tmp"
    try:
        chunks.assemble_chunks(upload_id, session.total_chunks, assembled_path)
        project_id, job_id = await finalize_upload(
            local_path=assembled_path,
            declared_mime=session.mime_type,
            original_filename=session.original_filename,
            project_name=session.project_name,
            caption_language=session.caption_language,
            translate_to=session.translate_to,
            size_bytes=session.total_size_bytes,
            user_id=user_id,
            db=db,
        )
    except UploadValidationError as e:
        chunks.cleanup_session(upload_id)
        raise HTTPException(status_code=422, detail=str(e))

    session.status = "completed"
    await db.commit()
    chunks.cleanup_session(upload_id)  # chunks are no longer needed once the assembled file is in object storage

    return VideoUploadResponse(project_id=project_id, job_id=job_id)


@router.delete("/{upload_id}", status_code=204)
async def cancel_upload(upload_id: str, user_id: str = Depends(get_current_user_id), db: AsyncSession = Depends(get_db)):
    session = await _get_owned_session(upload_id, user_id, db)
    chunks.cleanup_session(upload_id)
    session.status = "cancelled"
    await db.commit()
