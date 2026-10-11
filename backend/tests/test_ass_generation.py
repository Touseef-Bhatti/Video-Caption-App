"""
Covers ASS subtitle generation: time formatting, one-Dialogue-event-per-word
output, RTL font selection, hex->ASS color conversion, style-override
merging, validity of the premium presets, free positioning, and the
weight-driven motion behavior used by animated templates.
"""
from services.ffmpeg_service import (
    CAPTION_PRESETS,
    RTL_FONTS,
    _ass_time,
    _hex_to_ass_color,
    merge_style,
    build_ass_subtitle,
)
from schemas.schemas import GeminiTranscriptResponse, GeminiSegment, GeminiWord


# ---------------------------------------------------------------------------
# _ass_time
# ---------------------------------------------------------------------------
def test_ass_time_formats_zero():
    assert _ass_time(0.0) == "0:00:00.00"


def test_ass_time_formats_minutes_seconds_centiseconds():
    # 1 hour, 2 minutes, 3.45 seconds
    assert _ass_time(3723.45) == "1:02:03.45"


# ---------------------------------------------------------------------------
# RTL font selection
# ---------------------------------------------------------------------------
def test_rtl_fonts_known_for_urdu_and_arabic():
    assert RTL_FONTS["urdu"] == "Noto Nastaliq Urdu"
    assert RTL_FONTS["arabic"] == "Noto Naskh Arabic"


# ---------------------------------------------------------------------------
# _hex_to_ass_color
# ---------------------------------------------------------------------------
def test_hex_to_ass_color_white():
    assert _hex_to_ass_color("#FFFFFF") == "&H00FFFFFF"


def test_hex_to_ass_color_red_byte_order_reversed():
    # ASS color order is BGR, not RGB -- #FF0000 (red) becomes blue=00 green=00 red=FF
    assert _hex_to_ass_color("#FF0000") == "&H000000FF"


def test_hex_to_ass_color_green():
    assert _hex_to_ass_color("#00FF00") == "&H0000FF00"


# ---------------------------------------------------------------------------
# merge_style
# ---------------------------------------------------------------------------
def test_merge_style_without_overrides_returns_preset_unchanged():
    merged = merge_style("classic", None)
    assert merged["primary"] == CAPTION_PRESETS["classic"]["primary"]
    assert merged["size"] == CAPTION_PRESETS["classic"]["size"]


def test_merge_style_overrides_primary_color_only():
    merged = merge_style("classic", {"primary_color": "#112233"})
    assert merged["primary"] == _hex_to_ass_color("#112233")
    # untouched fields fall back to the preset
    assert merged["size"] == CAPTION_PRESETS["classic"]["size"]
    assert merged["position"] == CAPTION_PRESETS["classic"]["position"]


def test_merge_style_overrides_font_size_and_position():
    merged = merge_style("minimal", {"font_size": 60, "position": "top"})
    assert merged["size"] == 60
    assert merged["position"] == "top"


# ---------------------------------------------------------------------------
# Premium presets are structurally valid
# ---------------------------------------------------------------------------
REQUIRED_PRESET_KEYS = {"font", "size", "primary", "highlight", "emphasis", "outline", "back", "bold", "position"}


def test_all_presets_have_required_keys_and_valid_position():
    visible_premium_ids = {
        "classic", "neon", "headline", "social", "karaoke",
        "comic", "creator", "news", "minimal", "cinematic",
    }
    assert visible_premium_ids.issubset(CAPTION_PRESETS)
    for name, preset in CAPTION_PRESETS.items():
        missing = REQUIRED_PRESET_KEYS - preset.keys()
        assert not missing, f"preset '{name}' missing keys: {missing}"
        assert preset["position"] in {"top", "center", "bottom"}


# ---------------------------------------------------------------------------
# build_ass_subtitle: one Dialogue event per word
# ---------------------------------------------------------------------------
def _sample_transcript(weight: float = 0.5) -> GeminiTranscriptResponse:
    return GeminiTranscriptResponse(
        language="English",
        segments=[
            GeminiSegment(
                start=0.0, end=2.0, text="Hello there friend", weight=weight,
                words=[
                    GeminiWord(text="Hello", start=0.0, end=0.6, style="normal"),
                    GeminiWord(text="there", start=0.6, end=1.2, style="highlight"),
                    GeminiWord(text="friend", start=1.2, end=2.0, style="emphasis"),
                ],
            )
        ],
    )


def test_build_ass_subtitle_emits_one_dialogue_per_word(tmp_path):
    out = tmp_path / "out.ass"
    build_ass_subtitle(_sample_transcript(), "classic", 1080, 1920, out)
    content = out.read_text(encoding="utf-8")
    dialogue_lines = [l for l in content.splitlines() if l.startswith("Dialogue:")]
    assert len(dialogue_lines) == 3  # 3 words -> 3 events


def test_build_ass_subtitle_uses_rtl_font_for_urdu(tmp_path):
    out = tmp_path / "out.ass"
    transcript = GeminiTranscriptResponse(
        language="Urdu",
        segments=[GeminiSegment(start=0.0, end=1.0, text="سلام", weight=0.5, words=[])],
    )
    build_ass_subtitle(transcript, "classic", 1080, 1920, out)
    content = out.read_text(encoding="utf-8")
    assert "Noto Nastaliq Urdu" in content


# ---------------------------------------------------------------------------
# Weight-driven premium motion
# ---------------------------------------------------------------------------
def test_dynamic_preset_scales_emphasis_word_proportional_to_weight(tmp_path):
    out = tmp_path / "out.ass"
    build_ass_subtitle(_sample_transcript(weight=0.9), "dynamic", 1080, 1920, out)
    content = out.read_text(encoding="utf-8")
    # The legacy dynamic ID maps to Viral Pop. Its active emphasis word
    # animates from 72% to a weight-derived 137%, then settles at 100%.
    assert "\\fscx72\\fscy72" in content
    assert "\\fscx137\\fscy137" in content


def test_dynamic_preset_no_scaling_for_low_weight_all_normal_segment(tmp_path):
    out = tmp_path / "out.ass"
    transcript = GeminiTranscriptResponse(
        language="English",
        segments=[
            GeminiSegment(
                start=0.0, end=1.0, text="so then", weight=0.1,
                words=[
                    GeminiWord(text="so", start=0.0, end=0.3, style="normal"),
                    GeminiWord(text="then", start=0.3, end=1.0, style="normal"),
                ],
            )
        ],
    )
    build_ass_subtitle(transcript, "dynamic", 1080, 1920, out)
    content = out.read_text(encoding="utf-8")
    # Normal words receive only restrained entrance motion; no high-weight
    # emphasis peak or decorative effect is added.
    assert "\\fscx137" not in content
    assert "✦" not in content


def test_manual_position_is_normalized_to_output_resolution(tmp_path):
    out = tmp_path / "positioned.ass"
    build_ass_subtitle(
        _sample_transcript(),
        "headline",
        1080,
        1920,
        out,
        style_overrides={"position_x": 0.25, "position_y": 0.4},
    )
    content = out.read_text(encoding="utf-8")
    assert "\\pos(270,768)" in content


def test_high_weight_emphasis_gets_template_effect(tmp_path):
    out = tmp_path / "effect.ass"
    build_ass_subtitle(_sample_transcript(weight=0.9), "comic", 1080, 1920, out)
    content = out.read_text(encoding="utf-8")
    assert "💥 friend" in content
