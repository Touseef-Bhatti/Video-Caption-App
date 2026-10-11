"""
Covers: filename safety (path-traversal protection), Gemini chunk-plan math
(single chunk for short videos, correct overlap/count for long ones),
Gemini schema validation (rejects bad timestamps, accepts valid data), and
container magic-byte sniffing.
"""
import pytest
from pydantic import ValidationError

from services.validation_service import safe_filename, sniff_container
from services.gemini_service import plan_chunks
from schemas.schemas import GeminiWord, GeminiSegment, GeminiTranscriptResponse


# ---------------------------------------------------------------------------
# safe_filename
# ---------------------------------------------------------------------------
def test_safe_filename_keeps_known_extension():
    assert safe_filename("my video.mp4", "job123") == "job123.mp4"


def test_safe_filename_rejects_unknown_extension():
    assert safe_filename("script.sh", "job123") == "job123.mp4"


def test_safe_filename_strips_path_traversal():
    # Even a malicious filename like "../../etc/passwd.mov" only ever
    # contributes its (whitelisted) extension -- the path itself is
    # entirely server-generated.
    result = safe_filename("../../../etc/passwd.mov", "job123")
    assert result == "job123.mov"
    assert ".." not in result
    assert "/" not in result


# ---------------------------------------------------------------------------
# plan_chunks
# ---------------------------------------------------------------------------
def test_plan_chunks_single_chunk_for_short_video():
    # Default gemini_chunk_seconds=600 -- a 5-minute video fits in one chunk.
    chunks = plan_chunks(300)
    assert len(chunks) == 1
    assert chunks[0].start == 0.0
    assert chunks[0].end == 300.0
    assert chunks[0].overlap_start == 0.0  # nothing to overlap before the very first chunk


def test_plan_chunks_30_minute_video_three_chunks_with_overlap():
    # 30 min = 1800s, chunk_seconds=600, overlap=5 -> 3 chunks of 600s each.
    chunks = plan_chunks(1800)
    assert len(chunks) == 3

    assert chunks[0].start == 0.0
    assert chunks[0].end == 600.0
    assert chunks[0].overlap_start == 0.0  # clamped to 0, nothing before the start

    assert chunks[1].start == 600.0
    assert chunks[1].end == 1200.0
    assert chunks[1].overlap_start == 595.0  # 600 - 5s backward overlap

    assert chunks[2].start == 1200.0
    assert chunks[2].end == 1800.0
    assert chunks[2].overlap_start == 1195.0


# ---------------------------------------------------------------------------
# Gemini schema validation
# ---------------------------------------------------------------------------
def test_gemini_word_rejects_end_before_start():
    with pytest.raises(ValidationError):
        GeminiWord(text="hi", start=2.0, end=1.0, style="normal")


def test_gemini_word_accepts_valid_timing():
    w = GeminiWord(text="hi", start=1.0, end=1.5, style="highlight")
    assert w.end >= w.start


def test_gemini_transcript_response_accepts_valid_payload():
    resp = GeminiTranscriptResponse(
        language="English",
        segments=[
            GeminiSegment(
                start=0.0, end=2.0, text="Hello there", weight=0.6,
                words=[
                    GeminiWord(text="Hello", start=0.0, end=0.9, style="normal"),
                    GeminiWord(text="there", start=0.9, end=2.0, style="highlight"),
                ],
            )
        ],
    )
    assert resp.segments[0].weight == 0.6
    assert len(resp.segments[0].words) == 2


def test_gemini_segment_weight_out_of_range_rejected():
    with pytest.raises(ValidationError):
        GeminiSegment(start=0.0, end=1.0, text="x", weight=1.5)


# ---------------------------------------------------------------------------
# Container sniffing
# ---------------------------------------------------------------------------
def test_sniff_container_rejects_non_video_bytes(tmp_path):
    fake = tmp_path / "not_a_video.mp4"
    fake.write_bytes(b"this is just plain text, not a real container")
    assert sniff_container(fake) is None


def test_sniff_container_accepts_mp4_ftyp_signature(tmp_path):
    fake = tmp_path / "video.mp4"
    # ftyp box: 4-byte size + "ftyp" at offset 4
    fake.write_bytes(b"\x00\x00\x00\x18ftypisom" + b"\x00" * 16)
    assert sniff_container(fake) == "video/mp4"


def test_sniff_container_accepts_mkv_ebml_header(tmp_path):
    fake = tmp_path / "video.mkv"
    fake.write_bytes(b"\x1a\x45\xdf\xa3" + b"\x00" * 32)
    assert sniff_container(fake) == "video/x-matroska"
