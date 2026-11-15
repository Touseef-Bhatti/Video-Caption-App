"""Modal hosts the Flutter web app, FastAPI, and all background processing.

Deploy from the repository root: python -m modal deploy modal_app.py
Database, private object storage, and Gemini settings come from Modal Secrets.
"""
import os
from pathlib import Path

import modal

ROOT = Path(__file__).resolve().parent
APP_NAME = os.environ.get("MODAL_APP_NAME", "video-caption-app")
SECRET_NAME = os.environ.get("MODAL_CONFIG_SECRET", "caption-app-config")
RENDER_GPU = os.environ.get("MODAL_RENDER_GPU", "auto")
MODAL_REGION = "us-east"
FUNCTION_SUFFIX = ""
STORAGE_PATH = "/mnt/modal-storage"
STORAGE_VOLUME_NAME = os.environ.get("MODAL_STORAGE_VOLUME", "caption-app-media")
GPU_REQUEST = (["T4", "L4", "A10"] if RENDER_GPU.lower() == "auto"
               else None if RENDER_GPU.lower() == "none" else RENDER_GPU)

app = modal.App(APP_NAME)
secret = modal.Secret.from_name(SECRET_NAME)
media_volume = modal.Volume.from_name(
    STORAGE_VOLUME_NAME, create_if_missing=True, version=2,
)
RUNTIME_ENV = {
    "PYTHONPATH": "/app",
    "ENVIRONMENT": "production",
    "JOB_BACKEND": "modal",
    "MODAL_APP_NAME": APP_NAME,
    "MODAL_FUNCTION_SUFFIX": FUNCTION_SUFFIX,
    "MODAL_RENDER_GPU": RENDER_GPU,
    "STORAGE_PROVIDER": "modal",
    "MODAL_STORAGE_VOLUME": STORAGE_VOLUME_NAME,
    "MODAL_STORAGE_PATH": STORAGE_PATH,
    "CHUNK_STORAGE_BACKEND": "object_storage",
    "TEMP_STORAGE_DIR": "/tmp/caption_app",
}
image = (
    modal.Image.from_dockerfile(ROOT / "backend" / "Dockerfile", context_dir=ROOT)
    .pip_install("modal==1.6.3")
    .env({
        **RUNTIME_ENV,
        "CAPTION_VIDEO_ENCODER": "auto",
        "CAPTION_ENCODER_THREADS": "0",
        "CAPTION_FILTER_THREADS": "2",
    })
)


@app.function(image=image, secrets=[secret], cpu=1, memory=2048,
              timeout=600, max_containers=2, min_containers=0,
              volumes={STORAGE_PATH: media_volume}, region=MODAL_REGION,
              routing_region=MODAL_REGION, name="web" + FUNCTION_SUFFIX)
@modal.concurrent(max_inputs=16)
@modal.asgi_app()
def web():
    os.environ.update(RUNTIME_ENV)
    # Web and API share an origin. Generate reset links for the deployed URL,
    # even when the old hosting URLs remain in the imported secret.
    public_url = os.environ.get("PUBLIC_APP_URL") or modal.Function.from_name(
        APP_NAME, "web" + FUNCTION_SUFFIX
    ).get_web_url()
    if not public_url:
        raise RuntimeError("The Modal web endpoint has no public URL.")
    os.environ.update(BACKEND_URL=public_url, FRONTEND_URL=public_url,
                      CORS_ALLOWED_ORIGINS=public_url)
    from app.main import app as api

    return api


@app.function(image=image, secrets=[secret], cpu=1, memory=2048,
              timeout=7200, max_containers=4, retries=0,
              volumes={STORAGE_PATH: media_volume}, region=MODAL_REGION,
              routing_region=MODAL_REGION, name="process_video_job" + FUNCTION_SUFFIX)
def process_video_job(job_id: str):
    os.environ.update(RUNTIME_ENV)
    from workers.tasks import process_video_job as process

    process.run(job_id)


@app.function(image=image, secrets=[secret], cpu=4, memory=8192,
              gpu=GPU_REQUEST,
              timeout=1800, max_containers=1, retries=0,
              volumes={STORAGE_PATH: media_volume}, region=MODAL_REGION,
              routing_region=MODAL_REGION, name="rerender_project_job" + FUNCTION_SUFFIX)
def rerender_project_job(
    job_id: str,
    quality: str = "standard",
    aspect_ratio: str = "original",
    output_resolution: int = 0,
    output_fps: int = 0,
):
    os.environ.update(RUNTIME_ENV)
    from workers.tasks import rerender_project_job as render

    render.run(job_id, quality, aspect_ratio, output_resolution, output_fps)


@app.function(image=image, secrets=[secret], cpu=0.25, memory=512,
              schedule=modal.Period(minutes=15), timeout=600, max_containers=1,
              # Scheduled functions use Modal's default us-east input plane.
              volumes={STORAGE_PATH: media_volume},
              name="cleanup_expired_files" + FUNCTION_SUFFIX)
def cleanup_expired_files():
    os.environ.update(RUNTIME_ENV)
    from workers.tasks import cleanup_expired_files as cleanup
    from workers.modal_recovery import recover_finished_jobs

    cleanup.run()
    recover_finished_jobs()


@app.function(image=image, secrets=[secret], cpu=2, memory=4096,
              timeout=86400, max_containers=1,
              volumes={STORAGE_PATH: media_volume}, region=MODAL_REGION,
              routing_region=MODAL_REGION)
def migrate_legacy_storage():
    """Copy all existing S3/R2 objects to the Modal Volume before cutover."""
    import boto3
    from botocore.client import Config

    os.environ.update(RUNTIME_ENV)
    from app.config import get_settings
    from services import storage_service

    settings = get_settings()
    volume = modal.Volume.from_name(STORAGE_VOLUME_NAME, version=2)
    volume.reload()
    migration_marker = Path(STORAGE_PATH) / ".modal-internal" / "r2-migration-v1"
    if migration_marker.is_file():
        return {"migrated": 0, "skipped": "Legacy storage migration already completed."}
    if not all((settings.storage_bucket, settings.storage_access_key,
                settings.storage_secret_key, settings.storage_endpoint_url)):
        raise RuntimeError(
            "Legacy S3/R2 credentials are required until the Modal storage migration completes."
        )

    legacy = boto3.client(
        "s3", region_name=settings.storage_region,
        endpoint_url=settings.storage_endpoint_url,
        aws_access_key_id=settings.storage_access_key,
        aws_secret_access_key=settings.storage_secret_key,
        config=Config(signature_version="s3v4"),
    )
    paginator = legacy.get_paginator("list_objects_v2")
    migrated = skipped = total_bytes = 0
    # Only copy object prefixes written by this application. The bucket may
    # also contain unrelated objects owned by another service.
    for prefix in ("uploads/", "exports/", "upload-chunks/"):
        for page in paginator.paginate(Bucket=settings.storage_bucket, Prefix=prefix):
            for item in page.get("Contents", []):
                key = item["Key"]
                destination = storage_service.local_path(key)
                destination.parent.mkdir(parents=True, exist_ok=True)
                if destination.is_file() and destination.stat().st_size == item["Size"]:
                    skipped += 1
                    total_bytes += item["Size"]
                    continue
                legacy.download_file(settings.storage_bucket, key, str(destination))
                volume.commit()
                if destination.stat().st_size != item["Size"]:
                    raise RuntimeError(f"Storage migration size check failed for {key}.")
                migrated += 1
                total_bytes += item["Size"]

    migration_marker.parent.mkdir(parents=True, exist_ok=True)
    migration_marker.write_text("complete\n", encoding="utf-8")
    volume.commit()
    volume.reload()
    return {"migrated": migrated, "already_present": skipped,
            "objects_verified": migrated + skipped, "bytes_verified": total_bytes}


@app.function(image=image, secrets=[secret], timeout=300, max_containers=1)
def migrate():
    """Run once before deploying, never on each API container startup."""
    import subprocess

    os.environ.update(RUNTIME_ENV)
    subprocess.run(["alembic", "upgrade", "head"], cwd="/app", check=True)


@app.function(image=image, secrets=[secret], cpu=2, memory=2048,
              gpu=GPU_REQUEST, timeout=120)
def check_render_hardware():
    """Explicit smoke check; allocates the selected GPU while it runs."""
    import subprocess
    from services.video_encoder import nvenc_available

    result = {"gpu_request": GPU_REQUEST, "nvenc_available": nvenc_available()}
    if GPU_REQUEST is not None:
        gpu = subprocess.run(["nvidia-smi", "--query-gpu=name,driver_version",
                              "--format=csv,noheader"], capture_output=True, text=True, timeout=20)
        result["gpu"] = gpu.stdout.strip()
    if not result["nvenc_available"]:
        probe = subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
             "-i", "color=c=black:s=320x240:d=0.1", "-frames:v", "1",
             "-c:v", "h264_nvenc", "-f", "null", "-"],
            capture_output=True, text=True, timeout=20,
        )
        result["nvenc_error"] = probe.stderr[-2000:]
    return result
