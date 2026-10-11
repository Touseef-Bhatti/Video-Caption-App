import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded

from app.config import get_settings
from app.limiter import limiter
from routes import (
    auth_routes,
    video_routes,
    job_routes,
    caption_routes,
    export_routes,
    project_routes,
    chunked_upload_routes,
    usage_routes,
    diagnostic_routes,
    template_routes,
)
from workers.tasks import recover_orphaned_jobs

settings = get_settings()
logger = logging.getLogger("app")

app = FastAPI(
    title="Video Caption Generator API",
    version="1.0.0",
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_allowed_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_routes.router)
app.include_router(video_routes.router)
app.include_router(video_routes.projects_router)
app.include_router(job_routes.router)
app.include_router(job_routes.projects_router)
app.include_router(caption_routes.router)
app.include_router(export_routes.router)
app.include_router(project_routes.router)
app.include_router(chunked_upload_routes.router)
app.include_router(usage_routes.router)
app.include_router(diagnostic_routes.router)
app.include_router(template_routes.router)


@app.on_event("startup")
async def on_startup() -> None:
    # Any job left in an in-progress state means a previous worker process
    # crashed mid-job (section 58) -- fail those cleanly on boot rather than
    # leaving them stuck forever.
    recover_orphaned_jobs()


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    # Never leak internals (stack traces, exception text) to the client --
    # log server-side, return a generic safe message.
    logger.exception("Unhandled exception on %s %s", request.method, request.url.path)
    return JSONResponse(status_code=500, content={"detail": "Something went wrong on our end. Please try again."})


@app.get("/api/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/api/config/public")
async def public_config() -> dict:
    """Only non-secret, client-safe config (never API keys, DB creds, or
    storage secrets -- section 20/53)."""
    return {
        "max_upload_size_mb": settings.max_upload_size_mb,
        "max_video_duration_seconds": settings.max_video_duration_seconds,
        "allowed_mime_types": settings.allowed_mime_list,
        "chunk_upload_default_chunk_size_bytes": 5 * 1024 * 1024,
    }
