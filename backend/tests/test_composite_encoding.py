from pathlib import Path
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from app.config import Settings
from services import flutter_render_service as render
from services import video_encoder
from services.render_scene import caption_snapshot, fingerprint


def settings(**overrides):
    return Settings(_env_file=None, jwt_secret="test", database_url="sqlite:///test",
                    gemini_api_key="test", **overrides)


def command(monkeypatch, config=None, *, width=1280, height=720, fps=30, quality="standard",
            encoder_crf=None, source_bitrate=None, nvenc_preset=None, nvenc_cq=None,
            encoder_maxrate=None, encoder_bufsize=None):
    monkeypatch.setattr(render, "get_settings", lambda: config or settings())
    return render._composite_command(Path("source.mp4"), Path("overlay.mkv"),
                                     Path("output.mp4"), "[0:v][1:v]overlay[out]",
                                     5.0, width, height, fps, quality,
                                     encoder_crf=encoder_crf,
                                     source_video_bitrate_bps=source_bitrate,
                                     nvenc_preset=nvenc_preset, nvenc_cq=nvenc_cq,
                                     encoder_maxrate=encoder_maxrate,
                                     encoder_bufsize=encoder_bufsize)


def value(args, flag):
    return args[args.index(flag) + 1]


def test_software_command_and_audio_flags(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "libx264")
    args, effective = command(monkeypatch)
    assert value(args, "-c:v") == "libx264"
    assert value(args, "-preset") == "veryfast"
    assert value(args, "-crf") == "23"
    assert value(args, "-threads") == "4"
    assert value(args, "-filter_complex_threads") == "4"
    assert value(args, "-maxrate") == "2500k"
    assert value(args, "-bufsize") == "5000k"
    assert "-cq" not in args and "-rc" not in args and "-b:v" not in args
    assert args[args.index("-map") + 2:args.index("-fps_mode")] == ["-map", "0:a?"]
    assert value(args, "-c:a") == "copy"
    assert value(args, "-movflags") == "+faststart"
    assert effective["encoder_threads"] == 4


def test_nvenc_command_uses_nvenc_controls_not_libx264_settings(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "auto")
    monkeypatch.setattr(video_encoder, "nvenc_available", lambda: True)
    args, effective = command(monkeypatch, settings(h264_crf=30, h264_maxrate="9000k"),
                              source_bitrate=1_000_000)
    assert value(args, "-c:v") == "h264_nvenc"
    for flag in ("-crf", "-threads", "-filter_complex_threads"):
        assert flag not in args
    assert value(args, "-cq") == "28"
    assert value(args, "-maxrate") == "2000k"
    assert value(args, "-bufsize") == "4000k"
    assert value(args, "-rc") == "vbr"
    assert effective["effective_cq"] == "28"
    assert effective["effective_maxrate"] == "2000k"
    assert effective["effective_bufsize"] == "4000k"
    assert effective["encoder_threads"] is None


@pytest.mark.parametrize("width,height,expected", [
    (1280, 720, "2500k"),
    (1920, 1080, "5625k"),
    (3840, 2160, "22500k"),
])
def test_nvenc_unknown_source_uses_resolution_scaled_cap(monkeypatch, width, height, expected):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "h264_nvenc")
    monkeypatch.setattr(video_encoder, "nvenc_available", lambda: True)
    args, _ = command(monkeypatch, width=width, height=height, source_bitrate=None)
    assert value(args, "-maxrate") == expected
    assert value(args, "-bufsize") == f"{2 * int(expected[:-1])}k"


def test_nvenc_minimum_rate_and_explicit_profile_overrides(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "h264_nvenc")
    monkeypatch.setattr(video_encoder, "nvenc_available", lambda: True)
    args, _ = command(monkeypatch, source_bitrate=507_000)
    assert value(args, "-maxrate") == "1200k"
    assert value(args, "-bufsize") == "2400k"
    args, effective = command(monkeypatch, quality="high", encoder_crf=20,
                              nvenc_preset="p5", nvenc_cq=26,
                              encoder_maxrate="1800k", encoder_bufsize="3600k")
    assert value(args, "-preset") == "p5"
    assert value(args, "-cq") == "26"
    assert value(args, "-maxrate") == "1800k"
    assert value(args, "-bufsize") == "3600k"
    assert effective["crf"] is None


def test_nvenc_high_profile_keeps_its_existing_defaults(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "h264_nvenc")
    monkeypatch.setattr(video_encoder, "nvenc_available", lambda: True)
    args, effective = command(monkeypatch, settings(nvenc_cq=30), quality="high")
    assert value(args, "-preset") == "p6"
    assert value(args, "-cq") == "16"
    assert effective["crf"] is None


@pytest.mark.parametrize("width,height,expected", [
    (1280, 720, "2500k"),
    (1920, 1080, "5625k"),
    (3840, 2160, "20000k"),
])
def test_bitrate_scales_and_clamps(monkeypatch, width, height, expected):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "libx264")
    args, effective = command(monkeypatch, width=width, height=height)
    assert value(args, "-maxrate") == expected
    assert effective["bufsize"] == f"{2 * int(expected[:-1])}k"


def test_high_fps_and_high_quality_do_not_get_default_cap(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "libx264")
    args, _ = command(monkeypatch, fps=60)
    assert "-maxrate" not in args
    args, _ = command(monkeypatch, quality="high")
    assert value(args, "-crf") == "16"
    assert "-maxrate" not in args


def test_explicit_overrides_win(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "libx264")
    args, _ = command(monkeypatch, settings(h264_maxrate="9000k", h264_bufsize="18000k",
                                          ffmpeg_threads=2, ffmpeg_filter_threads=1),
                      width=3840, height=2160, quality="high", encoder_crf=19)
    assert value(args, "-maxrate") == "9000k"
    assert value(args, "-bufsize") == "18000k"
    assert value(args, "-crf") == "19"
    assert value(args, "-threads") == "2"
    assert value(args, "-filter_complex_threads") == "1"
    args, _ = command(monkeypatch, settings(h264_crf=21), quality="high")
    assert value(args, "-crf") == "21"


def test_filter_threads_default_to_encoder_threads():
    assert settings(ffmpeg_threads=7).ffmpeg_filter_threads == 7


@pytest.mark.parametrize("option,bad", [
    ("ffmpeg_threads", 0), ("ffmpeg_threads", 17),
    ("ffmpeg_filter_threads", 0), ("ffmpeg_filter_threads", 17),
    ("h264_crf", -1), ("h264_crf", 52),
    ("h264_maxrate", "0k"), ("h264_bufsize", "oops"),
    ("nvenc_cq", -1), ("nvenc_cq", 52),
    ("h264_min_maxrate", "invalid"), ("nvenc_maxrate_cap", "invalid"),
])
def test_invalid_encoding_settings_fail_on_load(option, bad):
    with pytest.raises(ValidationError):
        settings(**{option: bad})


def test_pipeline_version_invalidates_old_exports():
    caption = SimpleNamespace(caption_data={"segments": []}, style_preset="classic",
                              style_overrides={}, aspect_ratio="original")
    current = caption_snapshot(caption)
    previous = {**current, "render_pipeline_version": "chunked-10s-4workers-v1"}
    assert fingerprint(current) != fingerprint(previous)
