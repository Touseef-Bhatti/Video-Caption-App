"""
Centralized, typed settings loaded from environment variables.
Nothing here is ever sent to the Flutter client — see routes for the
explicit allowlist of config exposed via GET /api/config/public.
"""
from functools import lru_cache
from typing import Literal
from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    environment: str = "development"
    backend_url: str = "http://localhost:8000"
    frontend_url: str = "http://localhost:3000"
    cors_allowed_origins: str = "http://localhost:3000"

    jwt_secret: str
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 60

    database_url: str
    redis_url: str = "redis://localhost:6379/0"
    celery_broker_url: str = "redis://localhost:6379/0"
    celery_result_backend: str = "redis://localhost:6379/1"
    # Celery is retained for local Compose; Modal deployments need no Redis.
    job_backend: Literal["celery", "modal"] = "celery"
    modal_app_name: str = "video-caption-app"
    modal_function_suffix: str = ""
    chunk_storage_backend: Literal["local", "object_storage"] = "local"

    gemini_api_key: str
    gemini_model: str = "gemini-2.0-flash"
    gemini_max_retries: int = 3
    gemini_max_concurrency: int = 2
    gemini_chunk_seconds: int = 600
    gemini_chunk_overlap_seconds: int = 5

    storage_provider: Literal["s3", "modal"] = "s3"
    storage_bucket: str = "caption-app-storage"
    storage_access_key: str = ""
    storage_secret_key: str = ""
    storage_region: str = "auto"
    storage_endpoint_url: str = ""
    modal_storage_path: str = "/mnt/modal-storage"
    modal_storage_volume: str = "caption-app-media"

    max_video_duration_seconds: int = 3600
    max_upload_size_mb: int = 2048
    allowed_video_mime_types: str = "video/mp4,video/quicktime,video/x-matroska,video/webm"

    ffmpeg_threads: int = Field(default=4, ge=1, le=16)
    ffmpeg_filter_threads: int | None = Field(default=None, ge=1, le=16)
    render_capture_workers: int = Field(default=4, ge=1, le=16)
    h264_crf: int = Field(default=23, ge=0, le=51)
    h264_maxrate: str = "2500k"
    h264_bufsize: str = "5000k"
    h264_min_maxrate: str = "1200k"
    nvenc_maxrate_cap: str = "2500k"
    nvenc_cq: int = Field(default=28, ge=0, le=51)
    caption_render_strategy: Literal["legacy", "adaptive"] = "legacy"

    @model_validator(mode="after")
    def default_filter_threads(self):
        if self.ffmpeg_filter_threads is None:
            self.ffmpeg_filter_threads = self.ffmpeg_threads
        return self

    @field_validator("h264_maxrate", "h264_bufsize", "h264_min_maxrate", "nvenc_maxrate_cap")
    @classmethod
    def valid_bitrate(cls, value: str) -> str:
        import re
        if not re.fullmatch(r"[1-9][0-9]*[kKmM]?", value):
            raise ValueError("must be a positive FFmpeg bitrate (for example, 2500k)")
        return value

    @model_validator(mode="after")
    def nvenc_cap_not_below_minimum(self):
        def as_bps(value: str) -> int:
            suffix = value[-1:].lower()
            amount = int(value[:-1] if suffix in {"k", "m"} else value)
            return amount * (1_000 if suffix == "k" else 1_000_000 if suffix == "m" else 1)

        if as_bps(self.nvenc_maxrate_cap) < as_bps(self.h264_min_maxrate):
            raise ValueError("nvenc_maxrate_cap must be at least h264_min_maxrate")
        return self

    temp_storage_dir: str = "/tmp/caption_app"
    temp_file_retention_minutes: int = 60
    cleanup_interval_minutes: int = 15

    rate_limit_upload_per_hour: int = 10
    rate_limit_login_per_minute: int = 5

    @property
    def allowed_mime_list(self) -> list[str]:
        return [m.strip() for m in self.allowed_video_mime_types.split(",") if m.strip()]

    @property
    def cors_allowed_origins_list(self) -> list[str]:
        return [o.strip() for o in self.cors_allowed_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
