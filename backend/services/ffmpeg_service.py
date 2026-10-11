"""
All video/audio processing: probing, audio extraction, ASS subtitle
generation (word-level styling), and final burned-in-caption rendering.
Gemini never touches a video frame -- this module is the only thing that does.

Uses ASS (Advanced SubStation Alpha) instead of SRT/WebVTT because ASS is
what gives us per-word color changes, outlines, RTL-safe positioning, and
karaoke-style timing through libass -- none of which SRT supports.
"""
from __future__ import annotations

import json
import logging
import subprocess
from dataclasses import dataclass
from pathlib import Path

from schemas.schemas import GeminiTranscriptResponse

logger = logging.getLogger("ffmpeg_service")

RTL_LANGUAGES = {"urdu", "arabic", "persian", "farsi", "hebrew"}


# ---------------------------------------------------------------------------
# Probing
# ---------------------------------------------------------------------------
@dataclass
class VideoProbe:
    duration_seconds: float
    width: int
    height: int
    has_audio: bool
    mime_guess: str


def probe_video(path: Path) -> VideoProbe:
    """Uses ffprobe -- never trusts the client-reported duration/dimensions."""
    cmd = [
        "ffprobe", "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", str(path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise ValueError("Could not read this video file. It may be corrupted or in an unsupported format.")

    data = json.loads(result.stdout)
    fmt = data.get("format", {})
    streams = data.get("streams", [])
    video_stream = next((s for s in streams if s.get("codec_type") == "video"), None)
    audio_stream = next((s for s in streams if s.get("codec_type") == "audio"), None)

    if video_stream is None:
        raise ValueError("No video stream found in this file.")

    duration = float(fmt.get("duration") or video_stream.get("duration") or 0.0)
    width = int(video_stream.get("width") or 0)
    height = int(video_stream.get("height") or 0)
    sar = video_stream.get("sample_aspect_ratio", "1:1")
    try:
        numerator, denominator = map(int, sar.split(":"))
        if numerator > 0 and denominator > 0:
            width = round(width * numerator / denominator)
    except (ValueError, AttributeError):
        pass
    rotation = next((s["rotation"] for s in video_stream.get("side_data_list", [])
                     if "rotation" in s), video_stream.get("tags", {}).get("rotate", 0))
    if round(float(rotation)) % 180 == 90:
        width, height = height, width
    return VideoProbe(
        duration_seconds=duration,
        width=width,
        height=height,
        has_audio=audio_stream is not None,
        mime_guess=fmt.get("format_name", ""),
    )


def validate_duration(probe: VideoProbe, max_seconds: int) -> None:
    if probe.duration_seconds <= 0:
        raise ValueError("Could not determine video duration.")
    if probe.duration_seconds > max_seconds:
        minutes = max_seconds // 60
        raise ValueError(f"Video is too long. Maximum supported duration is {minutes} minutes.")


# ---------------------------------------------------------------------------
# Audio extraction (streamed to disk, never held fully in memory)
# ---------------------------------------------------------------------------
def extract_audio(video_path: Path, out_path: Path) -> Path:
    cmd = [
        "ffmpeg", "-y", "-i", str(video_path),
        "-ac", "1", "-ar", "16000", "-vn",
        str(out_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        logger.error("Audio extraction failed: %s", result.stderr[-2000:])
        raise RuntimeError("Could not extract audio from this video.")
    return out_path


# ---------------------------------------------------------------------------
# Caption style presets -> ASS style definitions
#
# Colors below are stored as ASS hex (&HAABBGGRR) because that's the format
# libass consumes directly. User color overrides from the API arrive as
# ordinary "#RRGGBB" web hex and are converted with _hex_to_ass_color()
# before ever reaching here -- see merge_style().
# ---------------------------------------------------------------------------
CAPTION_PRESETS: dict[str, dict] = {
    # Ten premium presets mirrored by the Flutter editor. Motion names are
    # interpreted below as ASS transform sequences, so animation survives
    # the final burned-in export instead of existing only in the preview.
    "classic": {"font": "Noto Sans", "size": 52, "primary": "&H00FFFFFF", "highlight": "&H0000D7FF",
                "emphasis": "&H000066FF", "outline": 0, "back": "&H47000000", "bold": True,
                "position": "center", "motion": "pop", "effect": "✦", "scales_with_weight": True},
    "neon": {"font": "Noto Sans", "size": 48, "primary": "&H00FFFFFF", "highlight": "&H00FFE500",
             "emphasis": "&H00922DFF", "outline": 0, "back": "&H26180C1A", "bold": True,
             "position": "center", "motion": "pulse", "effect": "✧", "scales_with_weight": True},
    "headline": {"font": "Noto Sans", "size": 44, "primary": "&H00FFFFFF", "highlight": "&H00C1F1FF",
                 "emphasis": "&H00FFFFFF", "outline": 0, "back": "&H10006AFF", "bold": True,
                 "position": "bottom", "motion": "slide", "effect": "◆", "scales_with_weight": True},
    "social": {"font": "Noto Sans", "size": 50, "primary": "&H00FFFFFF", "highlight": "&H0000F0FF",
               "emphasis": "&H0000A2FF", "outline": 0, "back": "&H47000000", "bold": True,
               "position": "center", "motion": "bounce", "effect": "🔥", "scales_with_weight": True},
    "karaoke": {"font": "Noto Sans", "size": 46, "primary": "&H00C8C8C8", "highlight": "&H0000D7FF",
                "emphasis": "&H00008AFF", "outline": 0, "back": "&H38000000", "bold": True,
                "position": "bottom", "motion": "karaoke", "effect": "♪", "scales_with_weight": True},
    "comic": {"font": "Noto Sans", "size": 52, "primary": "&H00FFFFFF", "highlight": "&H0000D7FF",
              "emphasis": "&H00303BFF", "outline": 0, "back": "&H261B1B22", "bold": True,
              "position": "center", "motion": "impact", "effect": "💥", "scales_with_weight": True},
    "creator": {"font": "Noto Sans", "size": 44, "primary": "&H00FFFFFF", "highlight": "&H006B6BFF",
                "emphasis": "&H00922DFF", "outline": 0, "back": "&H261E1E24", "bold": True,
                "position": "bottom", "motion": "zoom", "effect": "●", "scales_with_weight": True},
    "news": {"font": "Noto Sans", "size": 40, "primary": "&H00FFFFFF", "highlight": "&H00D6F4FF",
             "emphasis": "&H0066D1FF", "outline": 0, "back": "&H0B045DE8", "bold": True,
             "position": "bottom", "motion": "slide", "effect": "⚡", "scales_with_weight": True},
    "minimal": {"font": "Noto Sans", "size": 38, "primary": "&H00FFFFFF", "highlight": "&H00E3FFB8",
                "emphasis": "&H00FFFFFF", "outline": 0, "back": "&H70000000", "bold": False,
                "position": "bottom", "motion": "fade", "effect": "", "scales_with_weight": False},
    "cinematic": {"font": "Noto Serif", "size": 42, "primary": "&H00EDEDED", "highlight": "&H008AD9FF",
                  "emphasis": "&H0047B3FF", "outline": 0, "back": "&H66000000", "bold": False,
                  "position": "bottom", "motion": "cinematic", "effect": "✦", "scales_with_weight": True},
}

# Preserve projects saved with the previous preset IDs. These aliases are not
# shown in the new template picker but continue to render with a close premium
# replacement instead of silently falling back to another look.
for _legacy_id, _replacement in {
    "clean": "minimal",
    "bold": "comic",
    "highlight": "creator",
    "dynamic": "classic",
    "elegant": "cinematic",
}.items():
    CAPTION_PRESETS[_legacy_id] = dict(CAPTION_PRESETS[_replacement])

RTL_FONTS = {"urdu": "Noto Nastaliq Urdu", "arabic": "Noto Naskh Arabic", "persian": "Noto Naskh Arabic"}


def _hex_to_ass_color(hex_color: str, alpha_hex: str = "00") -> str:
    """Converts ordinary "#RRGGBB" web hex (what a color picker gives you)
    into ASS's "&HAABBGGRR" format (alpha + reversed byte order)."""
    h = hex_color.lstrip("#")
    if len(h) != 6:
        raise ValueError(f"Invalid color: {hex_color}")
    r, g, b = h[0:2], h[2:4], h[4:6]
    return f"&H{alpha_hex}{b}{g}{r}".upper()


def merge_style(style_preset: str, style_overrides: dict | None) -> dict:
    """Layers a user's custom colors/size/position (style_overrides, plain
    #RRGGBB hex from the API) on top of a named preset. Any field the user
    hasn't customized falls back to the preset's own value -- this is what
    lets every one of the 11 presets below be a starting point rather than
    a fixed, uneditable look (spec: "user should be able to... change text
    color, change background... change position")."""
    preset = dict(CAPTION_PRESETS.get(style_preset, CAPTION_PRESETS["classic"]))
    style_overrides = style_overrides or {}

    if style_overrides.get("primary_color"):
        preset["primary"] = _hex_to_ass_color(style_overrides["primary_color"])
    if style_overrides.get("highlight_color"):
        preset["highlight"] = _hex_to_ass_color(style_overrides["highlight_color"])
    if style_overrides.get("emphasis_color"):
        preset["emphasis"] = _hex_to_ass_color(style_overrides["emphasis_color"])
    if style_overrides.get("background_color"):
        preset["back"] = _hex_to_ass_color(style_overrides["background_color"], alpha_hex="40")
    if style_overrides.get("font_size"):
        preset["size"] = int(style_overrides["font_size"])
    if style_overrides.get("bold") is not None:
        preset["bold"] = bool(style_overrides["bold"])
    if style_overrides.get("position"):
        preset["position"] = style_overrides["position"]
    if style_overrides.get("position_x") is not None:
        preset["position_x"] = float(style_overrides["position_x"])
    if style_overrides.get("position_y") is not None:
        preset["position_y"] = float(style_overrides["position_y"])

    # Premium templates use background panels, never renderer-only outlines.
    preset["outline"] = 0
    return preset


def _ass_time(seconds: float) -> str:
    cs = int(round(seconds * 100))
    h, rem = divmod(cs, 360000)
    m, rem = divmod(rem, 6000)
    s, cs = divmod(rem, 100)
    return f"{h:01d}:{m:02d}:{s:02d}.{cs:02d}"


def _alignment_for_position(position: str) -> int:
    # libass \an alignment codes: 2=bottom-center, 5=middle-center, 8=top-center
    return {"bottom": 2, "center": 5, "top": 8}[position]


def _position_for_style(preset: dict) -> tuple[float, float]:
    """Return a safe normalized caption center for ASS position tags."""
    default_y = {"top": 0.17, "center": 0.52, "bottom": 0.82}[preset["position"]]
    x = max(0.05, min(0.95, float(preset.get("position_x", 0.5))))
    y = max(0.05, min(0.95, float(preset.get("position_y", default_y))))
    return x, y


def _motion_tags(preset: dict, weight: float, word_style: str, is_active: bool) -> str:
    """Build export-safe ASS animation tags for the active spoken word."""
    if not is_active:
        return ""

    motion = preset.get("motion", "fade")
    styled = word_style != "normal"
    strength = weight if styled else weight * 0.35
    if preset.get("scales_with_weight"):
        bonus = int(strength * (42 if word_style == "emphasis" else 24))
    else:
        bonus = int(strength * 8)
    peak = 100 + bonus

    if motion == "pop":
        return f"\\fscx72\\fscy72\\t(0,110,\\fscx{peak}\\fscy{peak})\\t(110,280,\\fscx100\\fscy100)"
    if motion == "pulse":
        return f"\\fscx96\\fscy96\\t(0,160,\\fscx{peak}\\fscy{peak})\\t(160,360,\\fscx100\\fscy100)"
    if motion == "bounce":
        return f"\\frz-3\\fscx90\\fscy90\\t(0,120,\\frz2\\fscx{peak}\\fscy{peak})\\t(120,300,\\frz0\\fscx100\\fscy100)"
    if motion == "impact":
        impact_peak = peak + 12
        return f"\\frz-5\\fscx60\\fscy60\\t(0,90,\\frz3\\fscx{impact_peak}\\fscy{impact_peak})\\t(90,260,\\frz0\\fscx100\\fscy100)"
    if motion == "zoom":
        return f"\\fscx82\\fscy82\\t(0,180,\\fscx{peak}\\fscy{peak})\\t(180,340,\\fscx100\\fscy100)"
    if motion == "slide":
        return f"\\fax-0.12\\fscx92\\t(0,200,\\fax0\\fscx{peak})\\t(200,360,\\fscx100)"
    if motion == "karaoke":
        return f"\\fscx100\\fscy100\\t(0,140,\\fscx{peak}\\fscy{peak})\\t(140,320,\\fscx100\\fscy100)"
    if motion == "cinematic":
        return f"\\alpha&H55&\\fsp4\\t(0,260,\\alpha&H00&\\fsp1\\fscx{peak}\\fscy{peak})\\t(260,440,\\fscx100\\fscy100)"
    return "\\alpha&H55&\\t(0,180,\\alpha&H00&)"


def build_ass_subtitle(
    transcript: GeminiTranscriptResponse,
    style_preset: str,
    video_width: int,
    video_height: int,
    out_path: Path,
    style_overrides: dict | None = None,
) -> Path:
    """
    Generates one ASS event PER WORD (not per segment) so each word can carry
    its own color based on its Gemini-assigned style, and so a word's
    highlight color can appear only during that word's own [start, end)
    window -- this is what gives "karaoke"/"dynamic" presets real per-word
    timing rather than a static per-line color.

    For the "dynamic" preset, a segment's Gemini-assigned `weight` (0-1,
    how important/emotional that line is in context) scales up how large
    its highlighted/emphasized words render -- a throwaway line stays flat,
    a high-weight punchline's key words visibly grow. This is the literal
    implementation of "words/phrases can scale... according to Gemini's
    instructions" from the style spec, driven by real context weight
    rather than a random/cosmetic effect.
    """
    preset = merge_style(style_preset, style_overrides)
    # Font sizes in the editor are authored against a 1080p reference. ASS
    # sizes are absolute pixels in the video's PlayRes, so scale them with
    # the actual output height; otherwise a 1080p editor setting becomes
    # visibly tiny on a 1920px-tall reel.
    preset["size"] = max(24, round(preset["size"] * video_height / 1080))
    is_rtl = transcript.language.strip().lower() in RTL_LANGUAGES
    font_name = RTL_FONTS.get(transcript.language.strip().lower(), preset["font"]) if is_rtl else preset["font"]
    position_x, position_y = _position_for_style(preset)
    pos_x = round(video_width * position_x)
    pos_y = round(video_height * position_y)
    margin_v = int(video_height * 0.08)

    header = f"""[Script Info]
ScriptType: v4.00+
PlayResX: {video_width}
PlayResY: {video_height}
ScaledBorderAndShadow: yes
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,{font_name},{preset["size"]},{preset["primary"]},{preset["primary"]},&H00000000,{preset["back"]},{-1 if preset["bold"] else 0},0,3,0,0,5,40,40,{margin_v},1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

    color_for_style = {
        "normal": preset["primary"],
        "highlight": preset["highlight"],
        "emphasis": preset["emphasis"],
    }

    lines = [header]
    for segment in transcript.segments:
        if not segment.words:
            # Fallback: no word-level data, render the whole segment plainly.
            text = _rtl_wrap(segment.text) if is_rtl else segment.text
            motion = _motion_tags(preset, segment.weight, "normal", True)
            lines.append(
                f"Dialogue: 0,{_ass_time(segment.start)},{_ass_time(segment.end)},Default,,0,0,0,,"
                f"{{\\an5\\pos({pos_x},{pos_y}){motion}}}{text}\n"
            )
            continue

        # One event per word-highlight-window: while this word is "active"
        # it renders in its style color; the rest of the segment's words
        # render in normal color during that same window, so the whole
        # caption line stays visible with only the active word changing.
        for i, word in enumerate(segment.words):
            parts = []
            for j, w in enumerate(segment.words):
                is_active = j == i
                colour = color_for_style[w.style] if is_active else preset["primary"]
                tags = f"\\c{colour}{_motion_tags(preset, segment.weight, w.style, is_active)}"
                token = w.text if not is_rtl else _rtl_wrap(w.text)
                effect = preset.get("effect", "")
                if is_active and effect and segment.weight >= 0.72 and w.style != "normal":
                    token = f"{effect} {token}"
                parts.append(f"{{{tags}}}{token}")
            line_text = " ".join(parts)
            lines.append(
                f"Dialogue: 0,{_ass_time(word.start)},{_ass_time(word.end)},Default,,0,0,0,,"
                f"{{\\an5\\pos({pos_x},{pos_y})}}{line_text}\n"
            )

    out_path.write_text("".join(lines), encoding="utf-8")
    return out_path


def _rtl_wrap(text: str) -> str:
    """Wraps text with Unicode RLE/PDF marks so libass keeps correct
    character ordering for Arabic-script languages mixed with Latin text."""
    RLE = "‫"
    PDF = "‬"
    return f"{RLE}{text}{PDF}"


# ---------------------------------------------------------------------------
# Final render
# ---------------------------------------------------------------------------
OUTPUT_DIMENSIONS = {
    "9:16": (1080, 1920),
    "1:1": (1080, 1080),
    "4:5": (1080, 1350),
    "16:9": (1920, 1080),
}


def output_dimensions(width: int, height: int, aspect_ratio: str = "original") -> tuple[int, int]:
    """Return a common delivery canvas, or the source dimensions unchanged."""
    if aspect_ratio in OUTPUT_DIMENSIONS:
        return OUTPUT_DIMENSIONS[aspect_ratio]
    return width - (width % 2), height - (height % 2)


QUALITY_PRESETS = {
    # Preserve caption panel/text colors as closely as broadly compatible
    # yuv420p H.264 permits; lower CRF reduces quantization on flat fills.
    "standard": {"crf": "18", "preset": "veryfast", "scale": None},
    "high":     {"crf": "16", "preset": "slow", "scale": None},
}


def render_captions(
    video_path: Path,
    ass_path: Path,
    out_path: Path,
    quality: str = "standard",
    aspect_ratio: str = "original",
) -> Path:
    """
    Burns the ASS subtitles into the video and re-encodes to H.264/AAC MP4.
    We re-encode (can't stream-copy) because burning subtitles requires
    decoding every frame -- but we use -preset veryfast by default to keep
    this reasonable for a 60-minute video, with "high" available for users
    who want better quality at a slower encode.
    """
    q = QUALITY_PRESETS.get(quality, QUALITY_PRESETS["standard"])
    # ass filter path must be escaped for ffmpeg's filter graph syntax
    escaped_ass = str(ass_path).replace("\\", "/").replace(":", "\\:")

    filters = []
    if aspect_ratio in OUTPUT_DIMENSIONS:
        target_width, target_height = OUTPUT_DIMENSIONS[aspect_ratio]
        filters.extend([
            f"scale={target_width}:{target_height}:force_original_aspect_ratio=decrease",
            f"pad={target_width}:{target_height}:(ow-iw)/2:(oh-ih)/2:color=black",
        ])
    filters.append(f"ass={escaped_ass}")

    cmd = [
        "ffmpeg", "-y", "-i", str(video_path),
        "-vf", ",".join(filters),
        "-c:v", "libx264", "-preset", q["preset"], "-crf", q["crf"],
        "-c:a", "aac", "-b:a", "128k",
        "-movflags", "+faststart",
        str(out_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        logger.error("Render failed: %s", result.stderr[-2000:])
        raise RuntimeError("Rendering the final video failed.")
    return out_path
