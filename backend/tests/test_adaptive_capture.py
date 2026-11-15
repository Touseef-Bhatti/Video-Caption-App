from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import pytest

from app.config import Settings
from services import flutter_render_service as render
from services.ffmpeg_service import VideoProbe
from services.render_scene import RENDERER_VERSION


class Page:
    def __init__(self, states, name="page"):
        self.states = states
        self.name = name
        self.screenshots = 0

    def evaluate(self, _script, seconds):
        import json
        return json.dumps(self.states[round(seconds * render.FPS)])


def test_adaptive_reuses_only_current_state_and_writes_every_slot(monkeypatch):
    page = Page([
        {"mode": "blank", "key": "blank"},
        {"mode": "blank", "key": "blank"},
        {"mode": "static", "key": "segment:0"},
        {"mode": "static", "key": "segment:0"},
        {"mode": "word_highlight", "key": "segment:0:word:1"},
    ])

    def screenshot(_page, frame, _count):
        page.screenshots += 1
        return [f"png-{frame}".encode()]

    monkeypatch.setattr(render, "capture_frames", screenshot)
    cache = {}
    result = [render.capture_overlay_png(page, frame, "adaptive", cache, 4, 4)
              for frame in range(5)]
    assert page.screenshots == 2
    assert len(result) == 5
    assert result[0][0] == result[1][0]
    assert result[2][0] == result[3][0]
    assert result[0][2] is False  # blank needs no Chromium screenshot
    assert [item[1] for item in result] == [
        "blank", "blank", "static", "static", "word_highlight"]


def test_capture_frames_reports_scene_update_wait_screenshot_and_png_bytes():
    class TimedPage:
        def evaluate(self, _script, _time):
            return '{"set_scene_time_seconds":0.001,"frame_wait_seconds":0.02}'

        def screenshot(self, **_kwargs):
            return b"png-frame"

    timings = {}
    frames = render.capture_frames(TimedPage(), 0, 1, timings)
    assert frames == [b"png-frame"]
    assert timings["set_scene_time_seconds"] == 0.001
    assert timings["frame_wait_seconds"] == 0.02
    assert timings["screenshot_seconds"] >= 0


def test_render_strategy_defaults_to_legacy_and_rejects_unknown_values(monkeypatch):
    required = {"_env_file": None, "jwt_secret": "test",
                "database_url": "sqlite:///test", "gemini_api_key": "test"}
    assert Settings(**required).caption_render_strategy == "legacy"
    monkeypatch.setenv("RENDER_CAPTURE_WORKERS", "6")
    assert Settings(**required).render_capture_workers == 6
    with pytest.raises(ValueError):
        Settings(**required, caption_render_strategy="unknown")


def test_chunk_cache_resets_and_concurrent_jobs_do_not_share_bytes(monkeypatch):
    def screenshot(page, frame, _count):
        page.screenshots += 1
        return [f"{page.name}:{frame}".encode()]

    monkeypatch.setattr(render, "capture_frames", screenshot)

    def run_job(name):
        page = Page([{"mode": "static", "key": "same"}] * 3, name)
        first_chunk = {}
        second_chunk = {}
        first = render.capture_overlay_png(page, 0, "adaptive", first_chunk, 4, 4)
        reused = render.capture_overlay_png(page, 1, "adaptive", first_chunk, 4, 4)
        new_chunk = render.capture_overlay_png(page, 2, "adaptive", second_chunk, 4, 4)
        return first, reused, new_chunk, page.screenshots

    with ThreadPoolExecutor(max_workers=2) as pool:
        a, b = list(pool.map(run_job, ("job-a", "job-b")))
    assert a[3] == b[3] == 2
    assert a[0][0] == a[1][0]
    assert a[0][0] != a[2][0]
    assert a[0][0] != b[0][0]


def test_capture_workers_pull_all_chunks_from_shared_queue(monkeypatch):
    import time

    def capture(_snapshot, _width, _height, _scale, start, end, _path, _log, _strategy):
        time.sleep(0.01)
        return {"start_frame": start, "end_frame": end}

    monkeypatch.setattr(render, "_capture_overlay_chunk", capture)
    work = render.Queue()
    for start in (0, 10, 20):
        work.put((start, start + 10, Path(f"{start}.mkv"), Path(f"{start}.log")))
    work.put(None)
    work.put(None)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(render._capture_overlay_worker, {}, 4, 4, 1, index, work)
                   for index in range(2)]
        results = [item for future in futures for item in future.result()]
    assert sorted(item["start_frame"] for item in results) == [0, 10, 20]


def test_chunk_writes_one_png_per_frame_slot_and_counts_modes(tmp_path, monkeypatch):
    written = []

    @contextmanager
    def browser(*_):
        yield object()

    class Process:
        stdin = SimpleNamespace(write=lambda data: written.append(data), close=lambda: None)

        def wait(self, timeout=None):
            return 0

    monkeypatch.setattr(render, "scene_browser", browser)
    monkeypatch.setattr(render, "load_scene", lambda *_: None)
    monkeypatch.setattr(render.subprocess, "Popen", lambda *_, **__: Process())
    frames = iter([(b"blank", "blank", False, 0.0),
                   (b"static", "static", True, 0.1),
                   (b"static", "static", False, 0.0)])
    monkeypatch.setattr(render, "capture_overlay_png", lambda *_, **__: next(frames))
    result = render._capture_overlay_chunk({}, 4, 4, 1, 0, 3,
                                           tmp_path / "overlay.mkv",
                                           tmp_path / "overlay.log", "adaptive")
    assert written == [b"blank", b"static", b"static"]
    assert result["frame_count"] == 3
    assert result["screenshots_captured"] == 1
    assert result["frames_reused"] == 1
    assert result["blank_frames"] == 1
    assert result["mode_counts"] == {"blank": 1, "static": 2,
                                     "word_highlight": 0, "legacy": 0}


def test_capture_failure_kills_encoder_and_removes_partial_overlay(tmp_path, monkeypatch):
    overlay = tmp_path / "overlay.mkv"
    log = tmp_path / "overlay.log"
    overlay.write_bytes(b"partial")

    @contextmanager
    def browser(*_):
        yield object()

    class Process:
        def __init__(self):
            self.stdin = SimpleNamespace(write=lambda _: None)
            self.killed = False

        def poll(self):
            return None

        def kill(self):
            self.killed = True

        def wait(self):
            return -1

    process = Process()
    monkeypatch.setattr(render, "scene_browser", browser)
    monkeypatch.setattr(render, "load_scene", lambda *_: None)
    monkeypatch.setattr(render.subprocess, "Popen", lambda *_, **__: process)
    monkeypatch.setattr(render, "capture_overlay_png", lambda *_, **__: (_ for _ in ()).throw(
        RuntimeError("cancelled")))
    with pytest.raises(RuntimeError, match="cancelled"):
        render._capture_overlay_chunk({}, 4, 4, 1, 0, 2, overlay, log, "adaptive")
    assert process.killed
    assert not overlay.exists()


def test_cancelled_render_removes_chunk_directory(tmp_path, monkeypatch):
    cfg = SimpleNamespace(caption_render_strategy="adaptive", ffmpeg_threads=4,
                          ffmpeg_filter_threads=4, h264_crf=23,
                          h264_maxrate="2500k", h264_bufsize="5000k",
                          model_fields_set=set())
    monkeypatch.setattr(render, "get_settings", lambda: cfg)
    monkeypatch.setattr(render, "encoder_options",
                        lambda *_: ("libx264", ["-c:v", "libx264", "-crf", "23"]))
    probe = VideoProbe(10.5, 160, 90, False, "mp4", frame_rate=30)
    output = tmp_path / "output.mp4"

    def fake_worker(_snapshot, _width, _height, _scale, _index, chunks, _strategy):
        results = []
        while True:
            chunk = chunks.get()
            if chunk is None:
                return results
            start, end, path, log = chunk
            path.write_bytes(b"partial overlay")
            log.write_text("partial log", encoding="utf-8")
            results.append({"start_frame": start, "end_frame": end})

    monkeypatch.setattr(render, "_capture_overlay_worker", fake_worker)
    calls = 0

    def cancel(_fraction):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise RuntimeError("cancelled")

    with pytest.raises(RuntimeError, match="cancelled"):
        render.render_scene(Path("source.mp4"),
                            {"renderer_version": RENDERER_VERSION,
                             "aspect_ratio": "original", "style_preset": "simple_white"},
                            output, progress=cancel, probe=probe)
    assert not (tmp_path / "output.caption_chunks").exists()
    assert not (tmp_path / "output.caption-overlay.mkv").exists()
    assert calls == 2
