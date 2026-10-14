"""
Pydantic schemas. GeminiTranscriptResponse is the strict contract the
Gemini service validates model output against (section 6) — if Gemini's
JSON doesn't satisfy this, we treat it as a malformed response, not data.
"""
from __future__ import annotations
from typing import Literal
from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

WordStyle = Literal["normal", "highlight", "emphasis"]


# ---------- Auth ----------
class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


# ---------- Gemini contract ----------
class GeminiWord(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)
    text: str
    start: float
    end: float
    style: WordStyle = "normal"
    emoji: str | None = Field(default=None, max_length=12)
    # Context importance used to decide which words share an on-screen line.
    weight: int = Field(default=50, ge=20, le=100)

    @field_validator("end")
    @classmethod
    def end_after_start(cls, v, info):
        start = info.data.get("start")
        if start is not None and v < start:
            raise ValueError("word end time precedes start time")
        return v


class GeminiSegment(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)
    start: float
    end: float
    text: str
    speaker: str | None = Field(default=None, max_length=100)
    words: list[GeminiWord] = Field(default_factory=list)
    # How important/emotionally weighted this line is, 0.0-1.0, as judged by
    # Gemini from context. Drives how much word-level styling a segment gets
    # (see gemini_service.SYSTEM_PROMPT) and, for the "dynamic" preset, how
    # much its emphasized words visually scale up.
    weight: float = Field(default=0.5, ge=0.0, le=1.0)
    # Optional per-caption-line placement saved by editor gestures.
    position_x: float | None = Field(default=None, ge=0.05, le=0.95)
    position_y: float | None = Field(default=None, ge=0.05, le=0.95)
    scale: float | None = Field(default=None, ge=0.5, le=2.0)
    rotation_degrees: float | None = Field(default=None, ge=-30, le=30)
    style_preset: str | None = Field(default=None, min_length=1, max_length=64)
    font_family: Literal["auto", "Caption Sans", "Caption Arabic", "Caption Urdu"] | None = None
    font_size: int | None = Field(default=None, ge=16, le=120)
    motion_enabled: bool | None = None


class GeminiTranscriptResponse(BaseModel):
    language: str
    segments: list[GeminiSegment]


# ---------- Jobs ----------
class JobStatusResponse(BaseModel):
    id: str
    project_id: str
    status: str
    stage: str
    progress: int
    error: str | None = None
    created_at: str

    @field_validator("created_at", mode="before")
    @classmethod
    def _stringify_created_at(cls, v):
        return v.isoformat() if hasattr(v, "isoformat") else v


# ---------- Video / project ----------
class VideoUploadResponse(BaseModel):
    project_id: str
    job_id: str


class ProjectSummary(BaseModel):
    id: str
    name: str
    status: str
    duration_seconds: float | None
    created_at: str


# ---------- Captions ----------
class StyleOverrides(BaseModel):
    """User-customized colors/sizing layered on top of a style_preset. Every
    field optional -- an unset field falls back to the preset's own value.
    Colors are plain "#RRGGBB" hex. Values are passed to the shared Flutter
    scene for both the editor preview and final video render."""
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    primary_color: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}$")
    highlight_color: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}$")
    emphasis_color: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}$")
    background_color: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}$")
    background_opacity: float | None = Field(default=None, ge=0.0, le=1.0)
    font_size: int | None = Field(default=None, ge=16, le=120)
    font_family: Literal["Caption Sans", "Caption Arabic", "Caption Urdu"] | None = None
    letter_spacing: float | None = Field(default=None, ge=-1.0, le=4.0)
    italic: bool | None = None
    bold: bool | None = None
    position: Literal["top", "center", "bottom"] | None = None
    # Normalized caption center coordinates. Keeping these independent of
    # pixels makes a hand-dragged position portable across every output ratio.
    position_x: float | None = Field(default=None, ge=0.05, le=0.95)
    position_y: float | None = Field(default=None, ge=0.05, le=0.95)
    scale: float | None = Field(default=None, ge=0.5, le=2.0)
    rotation_degrees: float | None = Field(default=None, ge=-30, le=30)
    emojis_enabled: bool | None = None
    motion_enabled: bool | None = None


class RenderRequest(BaseModel):
    """Optional body for POST /api/projects/{id}/render."""
    quality: Literal["standard", "high"] = "standard"
    aspect_ratio: Literal["original", "9:16", "1:1", "4:5", "16:9"] = "original"


class CaptionUpdateRequest(BaseModel):
    language: str | None = None
    style_preset: str | None = None
    caption_data: dict | None = None
    style_overrides: StyleOverrides | None = None
    aspect_ratio: Literal["original", "9:16", "1:1", "4:5", "16:9"] | None = None


class CaptionTranslateRequest(BaseModel):
    caption_data: dict
    target_language: str = Field(min_length=2, max_length=100)
