"""Resumable chunks use object storage on Modal and local files in Compose.

Each completed chunk has a deterministic name; retries replace that object.
The UploadSession row tracks metadata and ownership, while stored chunks
are the source of truth for resumability across API containers.
"""
from __future__ import annotations
import shutil
from pathlib import Path

from app.config import get_settings
from services import storage_service

settings = get_settings()

DEFAULT_CHUNK_SIZE_BYTES = 5 * 1024 * 1024  # 5 MB -- small enough to retry cheaply, large enough to not be chatty


def session_dir(upload_id: str) -> Path:
    return Path(settings.temp_storage_dir) / "uploads" / upload_id


def chunk_path(upload_id: str, chunk_index: int) -> Path:
    return session_dir(upload_id) / f"chunk_{chunk_index:06d}"


def chunk_prefix(upload_id: str) -> str:
    return f"upload-chunks/{upload_id}/"


def persist_chunk(upload_id: str, chunk_index: int, local_path: Path) -> None:
    if settings.chunk_storage_backend == "object_storage":
        storage_service.upload_file(local_path, chunk_prefix(upload_id) + chunk_path(upload_id, chunk_index).name)
        local_path.unlink(missing_ok=True)
    else:
        local_path.replace(chunk_path(upload_id, chunk_index))


def received_chunk_indices(upload_id: str, total_chunks: int) -> set[int]:
    if settings.chunk_storage_backend == "object_storage":
        prefix = chunk_prefix(upload_id)
        keys = set(storage_service.list_keys(prefix))
        return {i for i in range(total_chunks) if prefix + f"chunk_{i:06d}" in keys}
    d = session_dir(upload_id)
    if not d.exists():
        return set()
    received = set()
    for i in range(total_chunks):
        if chunk_path(upload_id, i).exists():
            received.add(i)
    return received


def assemble_chunks(upload_id: str, total_chunks: int, out_path: Path) -> Path:
    """Concatenates every chunk, in order, into one file. Raises if any
    chunk is missing -- the caller (the /complete endpoint) is expected to
    have already checked received_chunk_indices() covers every index, but
    this is the last line of defense against a race (a chunk deleted by
    cleanup between the check and the assembly)."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "wb") as out:
        for i in range(total_chunks):
            part = chunk_path(upload_id, i)
            if settings.chunk_storage_backend == "object_storage":
                part = out_path.with_suffix(".download")
                try:
                    storage_service.download_file(chunk_prefix(upload_id) + f"chunk_{i:06d}", part)
                    with open(part, "rb") as p:
                        shutil.copyfileobj(p, out, length=1024 * 1024)
                finally:
                    part.unlink(missing_ok=True)
                continue
            if not part.exists():
                raise ValueError(f"Missing chunk {i} of {total_chunks}. Please resend it before completing the upload.")
            with open(part, "rb") as p:
                shutil.copyfileobj(p, out, length=1024 * 1024)
    return out_path


def cleanup_session(upload_id: str) -> None:
    if settings.chunk_storage_backend == "object_storage":
        storage_service.delete_prefix(chunk_prefix(upload_id))
    shutil.rmtree(session_dir(upload_id), ignore_errors=True)
