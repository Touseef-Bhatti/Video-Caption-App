"""Pixel gate for the private Flutter renderer; run after rebuilding its web assets.

The gate compares every 15 fps slot in two 10-second-spanning snapshots for
every public preset. It uses the same PNG selection function as the worker.
"""
from __future__ import annotations

import os
from pathlib import Path
import struct
import zlib

import pytest

from services import flutter_render_service as render
from services.render_scene import RENDERER_VERSION
from services.template_catalog import list_templates


def _pixels(png: bytes) -> bytes:
    """Decode Chrome RGB/RGBA PNG rows, so comparison is by pixels, not encoding."""
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    position = 8
    compressed = bytearray()
    width = height = channels = 0
    while position < len(png):
        size = struct.unpack_from(">I", png, position)[0]
        kind = png[position + 4:position + 8]
        payload = png[position + 8:position + 8 + size]
        position += 12 + size
        if kind == b"IHDR":
            width, height, depth, colour = struct.unpack_from(">IIBB", payload)
            assert depth == 8 and colour in (2, 6)
            channels = 4 if colour == 6 else 3
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
    raw = zlib.decompress(compressed)
    stride = width * channels
    offset = 0
    previous = bytearray(stride)
    pixels = bytearray()
    for _ in range(height):
        filter_type = raw[offset]
        row = bytearray(raw[offset + 1:offset + 1 + stride])
        offset += stride + 1
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            above = previous[i]
            upper_left = previous[i - channels] if i >= channels else 0
            if filter_type == 1:
                row[i] = (row[i] + left) & 255
            elif filter_type == 2:
                row[i] = (row[i] + above) & 255
            elif filter_type == 3:
                row[i] = (row[i] + (left + above) // 2) & 255
            elif filter_type == 4:
                p = left + above - upper_left
                distances = (abs(p - left), abs(p - above), abs(p - upper_left))
                predictor = (left, above, upper_left)[distances.index(min(distances))]
                row[i] = (row[i] + predictor) & 255
            else:
                assert filter_type == 0
        if channels == 3:
            for i in range(0, stride, 3):
                pixels.extend(row[i:i + 3] + b"\xff")
        else:
            pixels.extend(row)
        previous = row
    return bytes(pixels)


def _word(text, start, end, style="normal"):
    return {"text": text, "start": start, "end": end, "style": style, "weight": 50}


def _segment(start, end, text, words):
    return {"start": start, "end": end, "text": text, "words": words,
            "weight": 50, "motion_enabled": False}


def _snapshot(preset, case):
    if case == "crossing":
        segments = [
            _segment(0.2, 1.6, "word gap overlap", [
                _word("word", 0.2, 0.5, "highlight"),
                _word("gap", 0.8, 1.2),
                _word("overlap", 1.0, 1.6, "emphasis")]),
            _segment(9.8, 10.4, "crossing boundary", [
                _word("crossing", 9.8, 10.1, "highlight"),
                _word("boundary", 10.1, 10.4)]),
        ]
    else:
        segments = [
            _segment(9.5, 10.0, "before", [_word("before", 9.5, 10.0)]),
            _segment(10.0, 10.4, "after", [_word("after", 10.0, 10.4, "highlight")]),
        ]
    return {"renderer_version": RENDERER_VERSION, "style_preset": preset,
            "style_overrides": {"motion_enabled": False},
            "caption_data": {"language": "English", "segments": segments}}


@pytest.mark.parametrize("preset", [item["id"] for item in list_templates()])
@pytest.mark.parametrize("case", ["crossing", "chunk_start_change"])
def test_every_preset_adaptive_matches_legacy_pixel_for_pixel(preset, case, monkeypatch):
    default_assets = Path(__file__).resolve().parents[2] / "frontend/build/renderer"
    assets = Path(os.environ.get("CAPTION_RENDERER_DIR", str(default_assets))).resolve()
    assert (assets / "main.dart.js").is_file(), "Build the private Flutter renderer first."
    built_script = (assets / "main.dart.js").read_bytes()
    assert RENDERER_VERSION.encode() in built_script and b"captionVisualStateKey" in built_script, (
        "Private renderer assets are stale; rebuild lib/render_main.dart before the pixel gate.")
    monkeypatch.setenv("CAPTION_RENDERER_DIR", str(assets))
    if os.name == "nt":
        monkeypatch.setenv("CAPTION_CHROMIUM_EXECUTABLE",
                           os.environ.get("CAPTION_CHROMIUM_EXECUTABLE",
                                          r"C:\Program Files\Google\Chrome\Application\chrome.exe"))
    snapshot = _snapshot(preset, case)
    with render.scene_browser(160, 90) as page:
        render.load_scene(page, snapshot, 160 / 1080)
        cache = {}
        for frame in range(156):
            if frame == 150:
                cache.clear()  # production cache is bounded to one chunk
            legacy, _, _, _ = render.capture_overlay_png(page, frame, "legacy", {}, 160, 90)
            adaptive, _, _, _ = render.capture_overlay_png(page, frame, "adaptive", cache, 160, 90)
            assert _pixels(adaptive) == _pixels(legacy), (
                f"preset={preset} case={case} frame={frame}")
