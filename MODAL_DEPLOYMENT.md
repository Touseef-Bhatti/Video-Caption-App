# Deploy the video caption app on Modal

Modal hosts the Flutter web frontend, FastAPI, transcription workers, video
export workers, and scheduled cleanup. Keep the existing PostgreSQL database,
private S3-compatible video storage, and Gemini API. No Render, Railway,
hosted Redis, Celery worker service, or Celery Beat service is required.
Local Docker Compose can still use Celery for development.

Live app: [Open Video Caption App](https://touseef12345bhatti--video-caption-app-web.us-east.modal.run/).
Manage it in the [Modal deployment dashboard](https://modal.com/apps/touseef12345bhatti/main/deployed/video-caption-app).
Live upload, transcription, GPU export, download, and browser playback checks
passed; see the [deployment verification report](backend/perf-reports/modal-deployment-2026-11-11.md).

## Deploy from PowerShell

Run from the repository root with Python 3.12 installed:

```powershell
python -m venv .venv-modal
.\.venv-modal\Scripts\python.exe -m pip install -r requirements-modal.txt
.\.venv-modal\Scripts\python.exe -m modal token new
.\deploy_modal.ps1
```

Finish Modal's browser login before running the deployment script. GPU use
requires a valid payment method in Modal. The script uploads `backend/.env`
to the private `caption-app-config` Modal Secret, runs existing Alembic
migrations once, and deploys `modal_app.py`. It prints the public web URL.
The Flutter web app and `/api/*` share that URL; Flutter uses its current
origin automatically. Build native mobile apps with
`--dart-define=API_BASE_URL=<the Modal web URL>`.

Ensure `backend/.env` contains reachable production values for `DATABASE_URL`,
`JWT_SECRET`, `GEMINI_API_KEY`, `GEMINI_MODEL`, and `STORAGE_*`. A localhost
database or a Docker Compose hostname such as `postgres` will not be reachable
from Modal. Preserve the existing JWT secret to keep issued login tokens valid.
The storage credentials must also permit listing and deleting temporary
objects under `upload-chunks/` in the existing bucket.

Secrets are excluded from the container build. Modal overrides the old hosting
settings `ENVIRONMENT`, `JOB_BACKEND`, `CHUNK_STORAGE_BACKEND`, and
`TEMP_STORAGE_DIR`. The API discovers its Modal URL for password reset links
and browser access. For a custom domain, configure it in Modal and include
`PUBLIC_APP_URL=https://your-domain` in the secret before redeploying.

## Runtime layout

| Function | Resources | Purpose |
|---|---|---|
| `web` | 1 CPU core, 2 GiB, at most 2 containers | Flutter files and FastAPI |
| `process_video_job` | 1 CPU core, 2 GiB, at most 4 containers | Audio extraction and Gemini transcription |
| `rerender_project_job` | L4 preferred, A10/T4 fallback, 2 CPU cores, 8 GiB, at most 2 containers | Caption graphics, compositing, video encoding |
| `cleanup_expired_files` | Every 15 minutes | Expired upload chunks and interrupted job recovery |
| `migrate` | Explicit one-off command | Alembic migrations |
| `check_render_hardware` | Explicit one-off command | Actual NVENC encode smoke test |

CPU values are physical cores. The web service scales to zero; the first
request can take longer while its container starts. GPU workers only run for
render jobs and hardware checks. Concurrency caps bound simultaneous resource
usage; they are not a dollar spending limit.

Modal dispatch replaces Redis/Celery in deployed containers. The existing
`processing_jobs.celery_task_id` column stores Modal `fc-` call IDs to preserve
the database schema. Status polling and ownership checks keep using the database.
Cancellation records the database state before stopping the Modal call. Workers
check cancellation before beginning work. Startup of a web container never
marks separate workers as interrupted. Scheduled recovery checks Modal call
results before marking unfinished database jobs as failed.

Upload chunks are stored privately in the existing bucket, so a different API
container can resume and assemble them. Containers only use local disk while
receiving, validating, or rendering files. Chunks are removed after completion
or cancellation; inactive upload sessions expire after the configured retention.

## GPU validation and CPU alternative

```powershell
.\.venv-modal\Scripts\python.exe -c "import json, modal; print(json.dumps(modal.Function.from_name('video-caption-app', 'check_render_hardware').remote(), indent=2))"
```

This command allocates an L4, A10, or T4 and incurs compute charges while it runs. It tests
an actual `h264_nvenc` encode, rather than assuming an encoder listed by FFmpeg
works. `CAPTION_VIDEO_ENCODER=auto` uses NVENC when this test succeeds and logs
a warning before falling back to `libx264` when it fails. Export diagnostics
record the selected encoder, preset, and quality controls. NVENC CQ and x264
CRF are different controls; equal numeric values do not establish equal quality.

Chromium still uses the existing software graphics path. Hardware video encoding
does not remove the per-frame screenshot cost or accelerate the Gemini API.
Benchmark total export time and visual quality before claiming a speed increase.

The default `-RenderGpu auto` prefers L4 and allows A10/T4 when L4 capacity is
unavailable. Use `-RenderGpu L4` to require L4, or deploy without a GPU:

```powershell
.\deploy_modal.ps1 -RenderGpu none
```

Use the same `MODAL_APP_NAME`, `MODAL_CONFIG_SECRET`, and `MODAL_RENDER_GPU`
environment variables for later manual Modal commands when using custom values.
Do not run `modal serve` against production data: dispatch looks up the deployed
app's worker functions. Deploy changes together with `modal deploy`.

## Verification

After deployment, open `/api/health`, register or sign in, upload a short video,
wait for captions, edit and save, export, and verify audio and caption appearance.
Also test upload resume, cancellation, and `/api/diagnostics/system` while signed
in. It reports Modal functions instead of requiring Redis. Production hides the
development-only Gemini and detailed rendering diagnostics endpoints.

Existing `railway.json`, shared-process startup files, and local Compose files
are not used by `modal_app.py`. Stop old hosted compute only after validating the
Modal deployment; keep the existing database and storage.

References: [ASGI web apps](https://modal.com/docs/guide/webhooks),
[background jobs](https://modal.com/docs/guide/job-queue),
[GPU setup](https://modal.com/docs/guide/gpu),
[pricing](https://modal.com/pricing).
