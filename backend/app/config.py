"""
Centralized, typed settings loaded from environment variables.
Nothing here is ever sent to the Flutter client — see routes for the
explicit allowlist of config exposed via GET /api/config/public.
"""
from functools import lru_cache
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

    gemini_api_key: str
    gemini_model: str = "gemini-2.0-flash"
    gemini_max_retries: int = 3
    gemini_chunk_seconds: int = 600
    gemini_chunk_overlap_seconds: int = 5

    storage_provider: str = "s3"
    storage_bucket: str = "caption-app-storage"
    storage_access_key: str = ""
    storage_secret_key: str = ""
    storage_region: str = "auto"
    storage_endpoint_url: str = ""

    max_video_duration_seconds: int = 3600
    max_upload_size_mb: int = 2048
    allowed_video_mime_types: str = "video/mp4,video/quicktime,video/x-matroska,video/webm"

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
