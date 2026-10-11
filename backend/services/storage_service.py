"""
S3-compatible object storage (works for AWS S3, Cloudflare R2, Supabase
Storage -- anything with an S3 API, set via STORAGE_ENDPOINT_URL).
Videos are never made public: everything is private, downloads go through
short-lived signed URLs only (section 19, 20).
"""
from __future__ import annotations
from pathlib import Path
import boto3
from botocore.client import Config
from app.config import get_settings

settings = get_settings()


def _client():
    return boto3.client(
        "s3",
        region_name=settings.storage_region,
        endpoint_url=settings.storage_endpoint_url or None,
        aws_access_key_id=settings.storage_access_key,
        aws_secret_access_key=settings.storage_secret_key,
        config=Config(signature_version="s3v4"),
    )


def upload_file(local_path: Path, storage_key: str) -> str:
    _client().upload_file(str(local_path), settings.storage_bucket, storage_key)
    return storage_key


def download_file(storage_key: str, local_path: Path) -> Path:
    _client().download_file(settings.storage_bucket, storage_key, str(local_path))
    return local_path


def delete_file(storage_key: str) -> None:
    _client().delete_object(Bucket=settings.storage_bucket, Key=storage_key)


def signed_download_url(
    storage_key: str,
    expires_seconds: int = 3600,
    *,
    download: bool = False,
    download_filename: str | None = None,
) -> str:
    params = {"Bucket": settings.storage_bucket, "Key": storage_key}
    if download:
        # Tell S3-compatible storage to return the rendered file as an
        # attachment. Without this, browsers commonly open MP4 files inline.
        filename = download_filename or Path(storage_key).name or "captioned-video.mp4"
        params.update(
            {
                "ResponseContentDisposition": f'attachment; filename="{filename}"',
                "ResponseContentType": "video/mp4",
            }
        )
    return _client().generate_presigned_url(
        "get_object",
        Params=params,
        ExpiresIn=expires_seconds,
    )
