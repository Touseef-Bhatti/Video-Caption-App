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
            encoder_crf=None):
    monkeypatch.setattr(render, "get_settings", lambda: config or settings())
    return render._composite_command(Path("source.mp4"), Path("overlay.mkv"),
                                     Path("output.mp4"), "[0:v][1:v]overlay[out]",
                                     5.0, width, height, fps, quality,
                                     encoder_crf=encoder_crf)


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
    assert args[args.index("-map") + 2:args.index("-fps_mode")] == ["-map", "0:a?"]
    assert value(args, "-c:a") == "copy"
    assert value(args, "-movflags") == "+faststart"
    assert effective["encoder_threads"] == 4


def test_nvenc_command_has_no_software_options(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "auto")
    monkeypatch.setattr(video_encoder, "nvenc_available", lambda: True)
    args, effective = command(monkeypatch, settings(h264_crf=30, h264_maxrate="9000k"))
    assert value(args, "-c:v") == "h264_nvenc"
    for flag in ("-crf", "-maxrate", "-bufsize", "-threads", "-filter_complex_threads"):
        assert flag not in args
    assert value(args, "-cq") == "18"
    assert effective["encoder_threads"] is None


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
