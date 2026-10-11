"""Approved, versioned caption template metadata and render setting checks.

The Flutter scene remains the renderer. These manifests describe its stable
public preset IDs and the safe settings accepted by the caption API.
"""
from __future__ import annotations

from copy import deepcopy
import math

from pydantic import ValidationError

from schemas.schemas import GeminiTranscriptResponse, StyleOverrides

TEMPLATE_VERSION = "1.0.0"
RENDERER = "flutter-scene"
ASPECT_RATIOS = ["original", "9:16", "1:1", "4:5", "16:9"]

# IDs mirror the curated Flutter catalog. Legacy aliases remain accepted for
# existing projects but are intentionally absent from the public gallery.
_items = [
    ("classic", "Viral Pop", "Dynamic", ["bold", "highlight", "animated"]),
    ("neon", "Neon Pulse", "Dynamic", ["neon", "animated"]),
    ("headline", "Golden Headline", "Dynamic", ["broadcast", "lower-third"]),
    ("social", "Social Bounce", "Dynamic", ["social", "animated"]),
    ("karaoke", "Karaoke Flow", "Dynamic", ["karaoke", "progressive"]),
    ("comic", "Comic Impact", "Dynamic", ["bold", "impact"]),
    ("creator", "Creator Card", "Dynamic", ["creator", "highlight"]),
    ("news", "Motion News", "Dynamic", ["broadcast", "lower-third"]),
    ("minimal", "Soft Minimal", "Common", ["minimal", "subtitles"]),
    ("cinematic", "Cinematic Glow", "Aesthetic", ["elegant", "serif"]),
    ("podcast_interview", "Podcast Interview", "Common", ["speaker-label", "interview"]),
    ("simple_white", "Simple White", "Simple", ["static", "shadow"]),
    ("clean_dark", "Clean Dark", "Common", ["static", "panel"]),
    ("soft_pastel", "Soft Pastel", "Aesthetic", ["static", "pastel"]),
    ("warm_aesthetic", "Warm Aesthetic", "Aesthetic", ["static", "warm"]),
    ("elegant_gold", "Elegant Gold", "Elegant", ["static", "gold"]),
    ("paper_note", "Paper Note", "Aesthetic", ["static", "paper"]),
    ("soft_shadow", "Soft Shadow", "Simple", ["static", "shadow"]),
    ("sage_minimal", "Sage Minimal", "Elegant", ["static", "sage"]),
    ("rose_elegant", "Rose Elegant", "Elegant", ["static", "rose"]),
    ("mono_clean", "Mono Clean", "Simple", ["static", "monochrome"]),
    ("blue_quiet", "Blue Quiet", "Elegant", ["static", "blue"]),
]

LEGACY_ALIASES = {
    "clean": "minimal",
    "bold": "comic",
    "highlight": "creator",
    "dynamic": "classic",
    "elegant": "cinematic",
}

_supported_settings = {
    "primary_color": {"type": "color", "format": "#RRGGBB"},
    "highlight_color": {"type": "color", "format": "#RRGGBB"},
    "emphasis_color": {"type": "color", "format": "#RRGGBB"},
    "background_color": {"type": "color", "format": "#RRGGBB", "opacity": 0.75},
    "background_opacity": {"type": "number", "minimum": 0.0, "maximum": 1.0},
    "font_size": {"type": "integer", "minimum": 16, "maximum": 120},
    "font_family": {"type": "enum", "values": ["Caption Sans", "Caption Arabic", "Caption Urdu"]},
    "letter_spacing": {"type": "number", "minimum": -1.0, "maximum": 4.0},
    "italic": {"type": "boolean"},
    "bold": {"type": "boolean"},
    "position": {"type": "enum", "values": ["top", "center", "bottom"]},
    "position_x": {"type": "number", "minimum": 0.05, "maximum": 0.95},
    "position_y": {"type": "number", "minimum": 0.05, "maximum": 0.95},
    "scale": {"type": "number", "minimum": 0.5, "maximum": 2.0},
    "rotation_degrees": {"type": "number", "minimum": -30, "maximum": 30},
    "emojis_enabled": {"type": "boolean"},
    "motion_enabled": {"type": "boolean"},
}

TEMPLATES = {
    template_id: {
        "id": template_id,
        "version": TEMPLATE_VERSION,
        "name": name,
        "description": f"{name} caption style.",
        "category": category,
        "tags": tags,
        "renderer": RENDERER,
        "renderer_version": "flutter-scene-v3",
        "supported_aspect_ratios": ASPECT_RATIOS,
        "supported_settings": _supported_settings,
        "defaults": {"motion_enabled": motion not in {"none"}},
        "compatibility": {"unicode": True, "rtl": True, "transparent_overlay": True},
        "optional_elements": ["speaker_label"] if template_id == "podcast_interview" else [],
        "resource_limits": {"max_segments": 10000, "max_words_per_segment": 200},
    }
    for template_id, name, category, tags in _items
    for motion in ({
        "classic": "pop", "neon": "pulse", "headline": "slide", "social": "bounce",
        "karaoke": "karaoke", "comic": "impact", "creator": "zoom", "news": "slide",
        "minimal": "fade", "cinematic": "cinematic",
    }.get(template_id, "none"),)
}


def list_templates() -> list[dict]:
    return [deepcopy(value) for value in TEMPLATES.values()]


def get_template(template_id: str) -> dict | None:
    item = TEMPLATES.get(template_id)
    return deepcopy(item) if item else None


def resolve_template_id(template_id: str) -> str | None:
    if template_id in TEMPLATES:
        return template_id
    return LEGACY_ALIASES.get(template_id)


def validate_caption_configuration(template_id: str, caption_data: dict,
                                   style_overrides: dict | None) -> tuple[str, dict, dict]:
    """Reject unknown templates and malformed transcript/style payloads."""
    resolved_id = resolve_template_id(template_id)
    if resolved_id is None:
        raise ValueError("Unsupported caption template.")
    try:
        transcript = GeminiTranscriptResponse.model_validate(caption_data)
        overrides = StyleOverrides.model_validate(style_overrides or {})
    except ValidationError as exc:
        raise ValueError("Caption text, timing, or style settings are invalid.") from exc

    if len(transcript.segments) > 10000:
        raise ValueError("This transcript has too many caption segments.")
    previous_start = -1.0
    for segment in transcript.segments:
        if (not math.isfinite(segment.start) or not math.isfinite(segment.end)
                or segment.start < 0 or segment.end <= segment.start
                or segment.start < previous_start):
            raise ValueError("Caption segment timing must be positive and ordered.")
        if not segment.text.strip():
            raise ValueError("Caption segments cannot be empty.")
        if len(segment.words) > 200:
            raise ValueError("A caption segment has too many words.")
        previous_start = segment.start
        previous_word_end = segment.start
        for word in segment.words:
            if (not math.isfinite(word.start) or not math.isfinite(word.end)
                    or word.start < segment.start or word.end > segment.end
                    or word.end <= word.start or word.start < previous_word_end):
                raise ValueError("Word timings must fall inside their caption segment.")
            previous_word_end = word.end

    return resolved_id, transcript.model_dump(), overrides.model_dump(exclude_none=True)
