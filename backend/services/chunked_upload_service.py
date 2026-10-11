"""
Filesystem side of resumable/chunked uploads. Chunks are written as
individual files (chunk_000000, chunk_000001, ...) under a per-session
directory. This is deliberately simple -- no database row tracks which
chunks arrived, because the filesystem itself is the source of truth and
a PUT of the same chunk index twice is naturally idempotent (it just
overwrites the same file). The UploadSession DB row only tracks the
session's own metadata (total size, chunk count, owner, status).
"""
from __future__ import annotations
import shutil
from pathlib import Path

from app.config import get_settings

settings = get_settings()

DEFAULT_CHUNK_SIZE_BYTES = 5 * 1024 * 1024  # 5 MB -- small enough to retry cheaply, large enough to not be chatty


def session_dir(upload_id: str) -> Path:
    return Path(settings.temp_storage_dir) / "uploads" / upload_id


def chunk_path(upload_id: str, chunk_index: int) -> Path:
    return session_dir(upload_id) / f"chunk_{chunk_index:06d}"


def received_chunk_indices(upload_id: str, total_chunks: int) -> set[int]:
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
            if not part.exists():
                raise ValueError(f"Missing chunk {i} of {total_chunks}. Please resend it before completing the upload.")
            with open(part, "rb") as p:
                shutil.copyfileobj(p, out, length=1024 * 1024)
    return out_path


def cleanup_session(upload_id: str) -> None:
    shutil.rmtree(session_dir(upload_id), ignore_errors=True)
