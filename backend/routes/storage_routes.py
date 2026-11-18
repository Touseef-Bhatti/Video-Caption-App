"""Serve private Modal Volume files through short-lived signed URLs."""
from __future__ import annotations

import mimetypes
from urllib.parse import quote

import aiofiles
from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import StreamingResponse

from app.config import get_settings
from services import storage_service

router = APIRouter(prefix="/api/storage", tags=["storage"])
settings = get_settings()
_BLOCK_SIZE = 1024 * 1024


@router.get("/{storage_key:path}")
async def serve_storage_object(
    storage_key: str,
    request: Request,
    expires: int = Query(...),
    download: int = Query(default=0),
    filename: str = Query(default=""),
    signature: str = Query(...),
):
    if settings.storage_provider != "modal":
        raise HTTPException(status_code=404, detail="Not found.")
    if download not in (0, 1) or not storage_service.verify_signed_url(
        storage_key, expires, bool(download), filename, signature
    ):
        raise HTTPException(status_code=403, detail="This download link has expired or is invalid.")

    try:
        path = await storage_service.snapshot_modal_file(storage_key)
    except ValueError:
        raise HTTPException(status_code=404, detail="File not found.") from None
    if path is None:
        raise HTTPException(status_code=404, detail="File not found.")

    size = path.stat().st_size
    start, end = 0, size - 1
    status_code = 200
    headers = {"Accept-Ranges": "bytes", "Cache-Control": "private, no-store"}
    range_header = request.headers.get("range")
    if range_header:
        try:
            unit, value = range_header.strip().split("=", 1)
            if unit != "bytes" or "," in value:
                raise ValueError
            first, last = value.split("-", 1)
            if first:
                start = int(first)
                end = min(int(last), size - 1) if last else size - 1
            else:
                suffix_length = int(last)
                if suffix_length <= 0:
                    raise ValueError
                start = max(0, size - suffix_length)
            if start >= size or end < start:
                raise ValueError
            status_code = 206
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        except (ValueError, TypeError):
            path.unlink(missing_ok=True)
            raise HTTPException(
                status_code=416,
                detail="Requested byte range is not satisfiable.",
                headers={"Content-Range": f"bytes */{size}"},
            ) from None

    headers["Content-Length"] = str(end - start + 1)
    if download:
        safe_filename = filename.replace("\r", "").replace("\n", "")
        headers["Content-Disposition"] = f"attachment; filename*=UTF-8''{quote(safe_filename)}"
    media_type = "video/mp4" if download else (mimetypes.guess_type(path.name)[0] or "application/octet-stream")

    async def file_chunks():
        try:
            async with aiofiles.open(path, "rb") as source:
                await source.seek(start)
                remaining = end - start + 1
                while remaining:
                    block = await source.read(min(_BLOCK_SIZE, remaining))
                    if not block:
                        break
                    remaining -= len(block)
                    yield block
        finally:
            path.unlink(missing_ok=True)

    return StreamingResponse(file_chunks(), status_code=status_code, media_type=media_type, headers=headers)
