"""Private object storage backed by S3-compatible storage or a Modal Volume."""
from __future__ import annotations

import hashlib
import hmac
import os
import shutil
import tempfile
import threading
import time
import asyncio
from pathlib import Path, PurePosixPath
from urllib.parse import quote, urlencode

import boto3
from botocore.client import Config
from boto3.s3.transfer import TransferConfig

from app.config import get_settings

settings = get_settings()

_TRANSFER_CONFIG = TransferConfig(
    multipart_threshold=8 * 1024 * 1024,
    multipart_chunksize=8 * 1024 * 1024,
    max_concurrency=4,
    use_threads=True,
)

# Modal volumes reject reloads while any file on that volume is open. Keep
# refresh/copy and mutation operations in this container mutually exclusive.
_volume_lock = threading.Lock()
_async_volume_lock = asyncio.Lock()


def _client():
    return boto3.client(
        "s3",
        region_name=settings.storage_region,
        endpoint_url=settings.storage_endpoint_url or None,
        aws_access_key_id=settings.storage_access_key,
        aws_secret_access_key=settings.storage_secret_key,
        config=Config(signature_version="s3v4"),
    )


def _safe_key(storage_key: str) -> PurePosixPath:
    key = PurePosixPath(storage_key)
    if not storage_key or key.is_absolute() or ".." in key.parts or "\\" in storage_key:
        raise ValueError("Invalid storage key.")
    return key


def _modal_root() -> Path:
    return Path(settings.modal_storage_path).resolve()


def local_path(storage_key: str) -> Path:
    """Return the mounted Modal Volume path for a validated object key."""
    return _modal_root().joinpath(*_safe_key(storage_key).parts)


def _volume():
    import modal

    return modal.Volume.from_name(settings.modal_storage_volume, version=2)


def _refresh_volume() -> None:
    if settings.storage_provider == "modal":
        with _volume_lock:
            _volume().reload()


async def snapshot_modal_file(storage_key: str) -> Path | None:
    """Refresh a Modal Volume and copy an object off-volume for streaming."""
    if settings.storage_provider != "modal":
        raise RuntimeError("Modal file snapshots require Modal object storage.")

    # The temporary copy lets the response stream without keeping a Volume
    # file open, so another request can safely reload the Volume meanwhile.
    async with _async_volume_lock:
        _volume_lock.acquire()
        snapshot_path: Path | None = None
        try:
            await _volume().reload.aio()
            source = local_path(storage_key)
            if not source.is_file():
                return None

            fd, snapshot_name = tempfile.mkstemp(prefix="caption-app-download-")
            os.close(fd)
            snapshot_path = Path(snapshot_name)
            await asyncio.to_thread(shutil.copyfile, source, snapshot_path)
            return snapshot_path
        except Exception:
            if snapshot_path is not None:
                snapshot_path.unlink(missing_ok=True)
            raise
        finally:
            _volume_lock.release()


def _commit_volume() -> None:
    if settings.storage_provider == "modal":
        with _volume_lock:
            _volume().commit()


def upload_file(local_file: Path, storage_key: str) -> str:
    if settings.storage_provider == "modal":
        with _volume_lock:
            destination = local_path(storage_key)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(local_file, destination)
            _volume().commit()
    else:
        _client().upload_file(
            str(local_file), settings.storage_bucket, storage_key,
            Config=_TRANSFER_CONFIG,
        )
    return storage_key


def download_file(storage_key: str, destination: Path) -> Path:
    if settings.storage_provider == "modal":
        with _volume_lock:
            _volume().reload()
            source = local_path(storage_key)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
    else:
        _client().download_file(
            settings.storage_bucket, storage_key, str(destination),
            Config=_TRANSFER_CONFIG,
        )
    return destination


def delete_file(storage_key: str) -> None:
    if settings.storage_provider == "modal":
        with _volume_lock:
            local_path(storage_key).unlink(missing_ok=True)
            _volume().commit()
    else:
        _client().delete_object(Bucket=settings.storage_bucket, Key=storage_key)


def list_keys(prefix: str) -> list[str]:
    if settings.storage_provider == "modal":
        with _volume_lock:
            _volume().reload()
            root = _modal_root()
            base = local_path(prefix) if prefix else root
            if base.is_file():
                return [base.relative_to(root).as_posix()]
            if not base.exists():
                return []
            return [
                path.relative_to(root).as_posix()
                for path in base.rglob("*")
                if path.is_file() and not path.relative_to(root).as_posix().startswith(".modal-internal/")
            ]

    pages = _client().get_paginator("list_objects_v2").paginate(
        Bucket=settings.storage_bucket, Prefix=prefix,
    )
    return [item["Key"] for page in pages for item in page.get("Contents", [])]


def delete_prefix(prefix: str) -> None:
    if settings.storage_provider == "modal":
        with _volume_lock:
            target = local_path(prefix)
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink(missing_ok=True)
            _volume().commit()
        return

    client = _client()
    keys = list_keys(prefix)
    for start in range(0, len(keys), 1000):
        result = client.delete_objects(
            Bucket=settings.storage_bucket,
            Delete={"Objects": [{"Key": key} for key in keys[start:start + 1000]]},
        )
        if result.get("Errors"):
            raise RuntimeError("Could not remove all temporary upload chunks.")


def _signed_url_signature(storage_key: str, expires: int, download: bool, filename: str) -> str:
    message = f"{storage_key}\n{expires}\n{int(download)}\n{filename}".encode()
    return hmac.new(settings.jwt_secret.encode(), message, hashlib.sha256).hexdigest()


def verify_signed_url(storage_key: str, expires: int, download: bool, filename: str, signature: str) -> bool:
    if expires < int(time.time()):
        return False
    try:
        expected = _signed_url_signature(storage_key, expires, download, filename)
    except (AttributeError, TypeError):
        return False
    return hmac.compare_digest(expected, signature)


def signed_download_url(
    storage_key: str,
    expires_seconds: int = 3600,
    *,
    download: bool = False,
    download_filename: str | None = None,
) -> str:
    if settings.storage_provider != "modal":
        params = {"Bucket": settings.storage_bucket, "Key": storage_key}
        if download:
            filename = download_filename or Path(storage_key).name or "captioned-video.mp4"
            params.update({
                "ResponseContentDisposition": f'attachment; filename="{filename}"',
                "ResponseContentType": "video/mp4",
            })
        return _client().generate_presigned_url(
            "get_object", Params=params, ExpiresIn=expires_seconds,
        )

    filename = download_filename or ""
    expires = int(time.time()) + expires_seconds
    signature = _signed_url_signature(storage_key, expires, download, filename)
    query = urlencode({
        "expires": expires,
        "download": int(download),
        "filename": filename,
        "signature": signature,
    })
    base_url = settings.backend_url.rstrip("/")
    return f"{base_url}/api/storage/{quote(storage_key, safe='/')}?{query}"


def storage_status() -> bool:
    if settings.storage_provider == "modal":
        return _modal_root().is_dir() and os.access(_modal_root(), os.R_OK | os.W_OK)
    return bool(settings.storage_bucket and settings.storage_access_key and settings.storage_secret_key)
