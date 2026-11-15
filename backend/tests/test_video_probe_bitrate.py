import json
from types import SimpleNamespace

from services import ffmpeg_service


def test_probe_uses_video_stream_bitrate_when_present(monkeypatch, tmp_path):
    payload = {
        "format": {"duration": "5", "format_name": "mov,mp4", "bit_rate": "4000000"},
        "streams": [{"codec_type": "video", "codec_name": "h264", "width": 1280,
                     "height": 720, "bit_rate": "2500000"}],
    }
    monkeypatch.setattr(ffmpeg_service.subprocess, "run", lambda *a, **k: SimpleNamespace(
        returncode=0, stdout=json.dumps(payload)))

    assert ffmpeg_service.probe_video(tmp_path / "source.mp4").bit_rate == 2_500_000


def test_probe_keeps_missing_video_bitrate_unknown(monkeypatch, tmp_path):
    payload = {
        "format": {"duration": "5", "format_name": "mov,mp4", "bit_rate": "4000000"},
        "streams": [{"codec_type": "video", "codec_name": "h264", "width": 1280,
                     "height": 720}],
    }
    monkeypatch.setattr(ffmpeg_service.subprocess, "run", lambda *a, **k: SimpleNamespace(
        returncode=0, stdout=json.dumps(payload)))

    assert ffmpeg_service.probe_video(tmp_path / "source.mp4").bit_rate is None
