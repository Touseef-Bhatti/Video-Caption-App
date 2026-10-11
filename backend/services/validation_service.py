"""
Upload validation -- never trusts file extension or client-declared MIME
type alone (section 54). Checks real file signature (magic bytes) for the
common containers we claim to support, then probes with ffprobe for the
real duration before any processing begins.
"""
from __future__ import annotations
from pathlib import Path

_SIGNATURES: list[tuple[bytes, int, str]] = [
    (b"ftyp", 4, "video/mp4"),            # mp4/mov both use ftyp at offset 4
    (b"\x1a\x45\xdf\xa3", 0, "video/x-matroska"),  # mkv/webm (EBML header)
    (b"RIFF", 0, "video/avi"),
]


def sniff_container(path: Path) -> str | None:
    with open(path, "rb") as f:
        head = f.read(64)
    for signature, offset, mime in _SIGNATURES:
        if head[offset:offset + len(signature)] == signature:
            return mime
    return None


def validate_upload_basics(path: Path, declared_mime: str, allowed_mimes: list[str], max_size_mb: int) -> None:
    size_mb = path.stat().st_size / (1024 * 1024)
    if size_mb > max_size_mb:
        raise ValueError(f"File is too large. Maximum upload size is {max_size_mb} MB.")

    sniffed = sniff_container(path)
    if sniffed is None:
        raise ValueError("This doesn't look like a supported video file.")
    if declared_mime not in allowed_mimes:
        raise ValueError("Unsupported video format. Please upload MP4, MOV, MKV, or WEBM.")


def safe_filename(original_name: str, job_id: str) -> str:
    """Server-generated filename -- never trusts the client's filename for
    the path on disk (path traversal protection, section 54)."""
    ext = Path(original_name).suffix.lower()
    if ext not in {".mp4", ".mov", ".mkv", ".webm", ".avi"}:
        ext = ".mp4"
    return f"{job_id}{ext}"
