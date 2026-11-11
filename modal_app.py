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
GPU_REQUEST = (["L4", "A10", "T4"] if RENDER_GPU.lower() == "auto"
               else None if RENDER_GPU.lower() == "none" else RENDER_GPU)

app = modal.App(APP_NAME)
secret = modal.Secret.from_name(SECRET_NAME)
RUNTIME_ENV = {
    "PYTHONPATH": "/app",
    "ENVIRONMENT": "production",
    "JOB_BACKEND": "modal",
    "MODAL_APP_NAME": APP_NAME,
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
              timeout=600, max_containers=2, min_containers=0)
@modal.concurrent(max_inputs=16)
@modal.asgi_app()
def web():
    os.environ.update(RUNTIME_ENV)
    # Web and API share an origin. Generate reset links for the deployed URL,
    # even when the old hosting URLs remain in the imported secret.
    public_url = os.environ.get("PUBLIC_APP_URL") or modal.Function.from_name(APP_NAME, "web").get_web_url()
    if not public_url:
        raise RuntimeError("The Modal web endpoint has no public URL.")
    os.environ.update(BACKEND_URL=public_url, FRONTEND_URL=public_url,
                      CORS_ALLOWED_ORIGINS=public_url)
    from app.main import app as api

    return api


@app.function(image=image, secrets=[secret], cpu=1, memory=2048,
              timeout=7200, max_containers=4, retries=0)
def process_video_job(job_id: str):
    os.environ.update(RUNTIME_ENV)
    from workers.tasks import process_video_job as process

    process.run(job_id)


@app.function(image=image, secrets=[secret], cpu=2, memory=8192,
              gpu=GPU_REQUEST,
              timeout=7200, max_containers=2, retries=0)
def rerender_project_job(job_id: str, quality: str = "standard", aspect_ratio: str = "original"):
    os.environ.update(RUNTIME_ENV)
    from workers.tasks import rerender_project_job as render

    render.run(job_id, quality, aspect_ratio)


@app.function(image=image, secrets=[secret], cpu=0.25, memory=512,
              schedule=modal.Period(minutes=15), timeout=600, max_containers=1)
def cleanup_expired_files():
    os.environ.update(RUNTIME_ENV)
    from workers.tasks import cleanup_expired_files as cleanup
    from workers.modal_recovery import recover_finished_jobs

    cleanup.run()
    recover_finished_jobs()


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
