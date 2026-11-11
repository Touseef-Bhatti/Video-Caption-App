import subprocess
from types import SimpleNamespace

import pytest

from services import video_encoder


@pytest.fixture(autouse=True)
def reset_nvenc_cache():
    video_encoder.nvenc_available.cache_clear()
    yield
    video_encoder.nvenc_available.cache_clear()


def test_auto_uses_software_when_actual_nvenc_encode_fails(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "auto")
    monkeypatch.setattr(video_encoder.subprocess, "run", lambda *a, **kw: SimpleNamespace(returncode=1))
    codec, args = video_encoder.encoder_options("standard", "veryfast", "18")
    assert codec == "libx264"
    assert args == ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18"]


def test_nvenc_uses_its_own_quality_controls(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "auto")
    monkeypatch.setattr(video_encoder.subprocess, "run", lambda *a, **kw: SimpleNamespace(returncode=0))
    codec, args = video_encoder.encoder_options("high", "slow", "16")
    assert codec == "h264_nvenc"
    assert "-crf" not in args
    assert args[args.index("-preset") + 1] == "p6"
    assert args[args.index("-cq") + 1] == "16"


def test_forced_nvenc_does_not_hide_missing_hardware(monkeypatch):
    monkeypatch.setenv("CAPTION_VIDEO_ENCODER", "h264_nvenc")
    monkeypatch.setattr(video_encoder, "nvenc_available", lambda: False)
    with pytest.raises(RuntimeError, match="unavailable"):
        video_encoder.encoder_options("standard", "veryfast", "18")


def test_nvenc_probe_timeout_is_safe(monkeypatch):
    def timeout(*args, **kwargs):
        raise subprocess.TimeoutExpired("ffmpeg", 20)
    monkeypatch.setattr(video_encoder.subprocess, "run", timeout)
    assert video_encoder.nvenc_available() is False
