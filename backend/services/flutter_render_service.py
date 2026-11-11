"""Render the very same Flutter scene used by the editor, then encode with FFmpeg.

No ASS translation or browser font substitution. The renderer is a private,
offline Flutter build. Only one transparent PNG frame is held in memory at a
time and frames are piped to FFmpeg; no video-sized frame directory is created.
"""
from __future__ import annotations

import atexit
import base64
from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import threading
import time
from urllib.parse import urlparse

from services.ffmpeg_service import QUALITY_PRESETS, output_dimensions, probe_video
from services.render_scene import FPS, RENDERER_VERSION

logger = logging.getLogger(__name__)


class _QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


class _SceneRuntime:
    """Keep one warm Flutter page and Chromium instance per worker process."""

    def __init__(self):
        self.lock = threading.Lock()
        self.server = None
        self.thread = None
        self.playwright = None
        self.browser = None
        self.page = None
        self.origin = None

    def _start(self, width, height):
        from playwright.sync_api import sync_playwright

        assets = Path(os.environ.get("CAPTION_RENDERER_DIR", "/opt/caption-renderer"))
        if not (assets / "main.dart.js").is_file():
            raise RuntimeError("Shared caption renderer is not built. Rebuild the worker image.")
        self.server = ThreadingHTTPServer(
            ("127.0.0.1", 0), partial(_QuietHandler, directory=str(assets))
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.playwright = sync_playwright().start()
        browser_args = ["--disable-dev-shm-usage", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
        if os.environ.get("CAPTION_RENDERER_LOW_MEMORY") == "1":
            browser_args.extend(["--single-process", "--no-zygote"])
        self.browser = self.playwright.chromium.launch(
            headless=True,
            executable_path="/usr/bin/chromium",
            args=browser_args,
        )
        self.page = self.browser.new_page(
            viewport={"width": width, "height": height}, device_scale_factor=1
        )
        self.page.on("pageerror", lambda error: logger.error("Caption renderer JavaScript error: %s", error))
        self.page.on("console", lambda message: logger.error("Caption renderer console: %s", message.text)
                     if message.type == "error" else None)
        self.page.on("crash", lambda _: logger.error("Caption renderer page crashed"))
        self.page.on("requestfailed", lambda request: logger.error(
            "Caption renderer request failed: %s (%s)", request.url, request.failure))
        # Transcript data stays local; no CDN/font/network requests are allowed.
        bundled_roboto = assets / "assets" / "fonts" / "Roboto-Variable.ttf"

        def fulfill_local_font(route):
            request_url = urlparse(route.request.url)
            if (request_url.hostname == "fonts.gstatic.com"
                    and request_url.path.startswith("/s/roboto/")):
                if not bundled_roboto.is_file():
                    raise RuntimeError("Bundled Roboto font is missing from the renderer image.")
                route.fulfill(path=str(bundled_roboto), content_type="font/ttf")
            elif route.request.url.startswith(self.origin + "/"):
                route.continue_()
            else:
                route.abort()

        self.page.route("**/*", fulfill_local_font)
        self.page.goto(self.origin, wait_until="load")
        self.page.wait_for_function("window.captionReady === true", timeout=60000)

    def close(self):
        for value in (self.page, self.browser):
            try:
                if value is not None:
                    value.close()
            except Exception:
                pass
        try:
            if self.playwright is not None:
                self.playwright.stop()
        except Exception:
            pass
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
        if self.thread is not None:
            self.thread.join(timeout=5)
        self.server = self.thread = self.playwright = self.browser = self.page = self.origin = None

    @contextmanager
    def use(self, width, height):
        with self.lock:
            try:
                if self.page is None or self.page.is_closed():
                    self._start(width, height)
                else:
                    self.page.set_viewport_size({"width": width, "height": height})
                yield self.page
            except Exception:
                # Recover from a crashed browser on the next render job.
                self.close()
                raise


_scene_runtime = _SceneRuntime()
atexit.register(_scene_runtime.close)


@contextmanager
def scene_browser(width, height):
    with _scene_runtime.use(width, height) as page:
        yield page


def load_scene(page, snapshot, canvas_scale=1.0):
    if snapshot.get("renderer_version") != RENDERER_VERSION:
        raise ValueError("Caption renderer version changed. Please render again.")
    render_snapshot = dict(snapshot)
    render_snapshot["canvas_scale"] = canvas_scale
    page.evaluate("scene => window.captionLoad(scene)", json.dumps(render_snapshot, ensure_ascii=False))


def capture_frame(page, time):
    return base64.b64decode(page.evaluate("t => window.captionFrame(t)", time), validate=True)


def capture_frames(page, start_frame: int, frame_count: int) -> list[bytes]:
    """Capture painted frames directly from Chromium as transparent PNGs.

    Flutter's legacy export bridge called RenderRepaintBoundary.toImage for
    every frame, encoded the full image as PNG inside Flutter, converted it to
    Base64, sent that string through Playwright, and decoded it in Python.
    Chromium already has the scene painted, so its native screenshot path
    avoids that duplicate rasterization and the Base64 round trip.
    """
    frames = []
    for frame in range(start_frame, start_frame + frame_count):
        page.evaluate("t => window.captionSetTime(t)", frame / FPS)
        frames.append(page.screenshot(type="png", omit_background=True, scale="css"))
    return frames


def _ffmpeg_progress(log_path: Path) -> dict:
    """Extract the last values printed by FFmpeg's normal progress line."""
    try:
        value = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}

    def last(pattern: str, cast):
        matches = re.findall(pattern, value)
        if not matches:
            return None
        try:
            return cast(matches[-1])
        except (TypeError, ValueError):
            return None

    parsed = {
        "frame": last(r"frame=\s*(\d+)", int),
        "fps": last(r"fps=\s*([\d.]+)", float),
        "speed_x": last(r"speed=\s*([\d.]+)x", float),
        "output_time": last(r"time=\s*([^\s]+)", str),
        "bitrate_kbits_per_second": last(r"bitrate=\s*([\d.]+)kbits/s", float),
    }
    return {key: item for key, item in parsed.items() if item is not None}


def _sanitized_command(cmd: list[str], video_path: Path, out_path: Path) -> list[str]:
    return [
        "<source_video>" if item == str(video_path)
        else "<output_video>" if item == str(out_path)
        else item
        for item in cmd
    ]


def _overlay_dimensions(width: int, height: int, maximum: int = 720) -> tuple[int, int]:
    """Fit the transparent caption layer inside 720p without enlarging it."""
    scale = min(1.0, maximum / max(width, height))
    return max(2, int(width * scale) // 2 * 2), max(2, int(height * scale) // 2 * 2)


def render_scene(video_path: Path, snapshot: dict, out_path: Path,
                 quality="standard", progress=None, probe=None,
                 encoder_preset=None, encoder_crf=None,
                 metrics: dict | None = None) -> Path:
    probe = probe or probe_video(video_path)
    width, height = output_dimensions(probe.width, probe.height, snapshot["aspect_ratio"])
    overlay_width, overlay_height = _overlay_dimensions(width, height)
    q = QUALITY_PRESETS.get(quality, QUALITY_PRESETS["standard"])
    preset = encoder_preset or q["preset"]
    crf = encoder_crf or q["crf"]
    count = max(1, math.ceil(probe.duration_seconds * FPS))
    overlay_path = out_path.with_name(out_path.stem + ".caption-overlay.mkv")
    caption_chain = f"[1:v]scale={width}:{height}:flags=lanczos,format=rgba[caption];"
    if (snapshot["style_preset"] == "liquid_glass"
            and snapshot.get("style_overrides", {}).get("liquid_glass_enabled", False)):
        graph = (f"[0:v]scale={width}:{height}:flags=lanczos,setsar=1,setpts=PTS-STARTPTS[video];{caption_chain}"
                 "[video]split[sharp][blur_source];"
                 "[blur_source]boxblur=16:1[blurred];"
                 "[caption]split[glass_overlay][glass_alpha];"
                 "[glass_alpha]alphaextract,lut=y='if(gte(val,24),255,0)'[glass_mask];"
                 "[sharp][blurred][glass_mask]maskedmerge[glass_video];"
                 "[glass_video][glass_overlay]overlay=0:0:eof_action=repeat:"
                 "repeatlast=1:shortest=0:format=auto,format=yuv420p[out]")
    else:
        graph = (f"[0:v]scale={width}:{height}:flags=lanczos,setsar=1,setpts=PTS-STARTPTS[video];{caption_chain}"
                 "[video][caption]overlay=0:0:eof_action=repeat:repeatlast=1:"
                 "shortest=0:format=auto,format=yuv420p[out]")
    overlay_cmd = ["ffmpeg", "-y", "-f", "image2pipe", "-vcodec", "png",
                   "-framerate", str(FPS), "-i", "pipe:0", "-an", "-c:v", "ffv1",
                   "-pix_fmt", "bgra", "-threads", "1", str(overlay_path)]
    cmd = ["ffmpeg", "-y", "-threads", "1", "-i", str(video_path), "-i", str(overlay_path),
           "-filter_complex_threads", "1", "-filter_complex", graph, "-map", "[out]",
           "-map", "0:a?", "-fps_mode", "passthrough", "-c:v", "libx264",
           "-preset", preset, "-crf", crf, "-threads", "1", "-c:a", "aac",
           "-b:a", "128k", "-t", str(probe.duration_seconds), "-movflags", "+faststart",
           str(out_path)]
    sanitized_cmd = _sanitized_command(cmd, video_path, out_path)
    if metrics is not None:
        metrics.update({
            "schema_version": 1,
            "renderer_version": RENDERER_VERSION,
            "capture_method": "chromium_transparent_png_screenshot",
            "input": {
                "width": probe.width,
                "height": probe.height,
                "duration_seconds": probe.duration_seconds,
                "has_audio": probe.has_audio,
                "container": probe.mime_guess,
                "video_codec": probe.video_codec,
                "frame_rate": probe.frame_rate,
                "pixel_format": probe.pixel_format,
                "bit_rate": probe.bit_rate,
                "audio_codec": probe.audio_codec,
            },
            "output": {"width": width, "height": height,
                       "frame_rate": probe.frame_rate},
            "caption_overlay": {"width": overlay_width, "height": overlay_height,
                                "frame_rate": FPS, "codec": "ffv1", "alpha": True},
            "workload": {
                "frames": count,
                "fps": FPS,
                "pixels_per_frame": overlay_width * overlay_height,
                "total_overlay_pixels": overlay_width * overlay_height * count,
            },
            "ffmpeg": {
                "command": sanitized_cmd,
                "command_text": shlex.join(sanitized_cmd),
                "filter_graph": graph,
                "filter_complex_threads": 1,
                "overlay_input_format": "ffv1/matroska/bgra",
                "video_codec": "libx264",
                "preset": preset,
                "crf": crf,
                "pixel_format": "yuv420p",
                "encoder_threads": 1,
                "audio_codec": "aac",
                "audio_bitrate": "128k",
                "movflags": "+faststart",
            },
        })
    render_started = time.perf_counter()
    browser_started = time.perf_counter()
    log_path = out_path.parent / "render.log"
    return_code = None
    with scene_browser(overlay_width, overlay_height) as page, log_path.open("wb") as log:
        browser_ready_seconds = time.perf_counter() - browser_started
        scene_started = time.perf_counter()
        load_scene(page, snapshot, overlay_width / width)
        scene_load_seconds = time.perf_counter() - scene_started
        ffmpeg_started = time.perf_counter()
        process = subprocess.Popen(overlay_cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=log)
        ffmpeg_start_seconds = time.perf_counter() - ffmpeg_started
        capture_seconds = 0.0
        pipe_write_seconds = 0.0
        pipe_bytes = 0
        try:
            last_progress_frame = -FPS
            for start in range(count):
                batch_count = 1
                if progress and start - last_progress_frame >= FPS:
                    progress(start / count * 0.82)
                    last_progress_frame = start
                capture_started = time.perf_counter()
                frames = capture_frames(page, start, batch_count)
                capture_seconds += time.perf_counter() - capture_started
                for frame_bytes in frames:
                    pipe_bytes += len(frame_bytes)
                    write_started = time.perf_counter()
                    process.stdin.write(frame_bytes)
                    pipe_write_seconds += time.perf_counter() - write_started
            process.stdin.close()
            drain_started = time.perf_counter()
            return_code = process.wait(timeout=max(120, probe.duration_seconds * 2))
            encoder_drain_seconds = time.perf_counter() - drain_started
            if return_code != 0:
                raise RuntimeError("Video encoding failed; see the worker render log.")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if not process.stdin.closed:
                process.stdin.close()
    composite_started = time.perf_counter()
    try:
        with log_path.open("ab") as log:
            composite_result = subprocess.run(
                cmd, stdout=subprocess.DEVNULL, stderr=log,
                timeout=max(180, probe.duration_seconds * 3),
            )
        if composite_result.returncode != 0:
            raise RuntimeError("Video compositing failed; see the worker render log.")
    finally:
        try:
            overlay_path.unlink(missing_ok=True)
        except OSError:
            logger.warning("Could not remove temporary caption overlay: %s", overlay_path.name)
    composite_seconds = time.perf_counter() - composite_started
    if progress:
        progress(0.98)
    if not out_path.is_file() or out_path.stat().st_size <= 0:
        raise RuntimeError("Video encoding produced no output file.")
    output_bytes = out_path.stat().st_size
    probe_started = time.perf_counter()
    output_probe = probe_video(out_path)
    output_probe_seconds = time.perf_counter() - probe_started
    if output_probe.width != width or output_probe.height != height:
        raise RuntimeError("Rendered video dimensions did not match the requested output.")
    if abs(output_probe.duration_seconds - probe.duration_seconds) > max(0.5, 2 / FPS):
        raise RuntimeError("Rendered video duration did not match the source video.")
    if output_probe.has_audio != probe.has_audio:
        raise RuntimeError("Rendered video audio track did not match the source video.")
    if (probe.frame_rate and output_probe.frame_rate
            and abs(output_probe.frame_rate - probe.frame_rate) > max(0.02, probe.frame_rate * 0.005)):
        raise RuntimeError("Rendered video frame rate did not match the source video.")
    total_seconds = time.perf_counter() - render_started
    phases = {
        "browser_ready": browser_ready_seconds,
        "scene_load": scene_load_seconds,
        "ffmpeg_start": ffmpeg_start_seconds,
        "frame_capture": capture_seconds,
        "pipe_write": pipe_write_seconds,
        "encoder_drain": encoder_drain_seconds,
        "full_resolution_composite": composite_seconds,
        "output_probe": output_probe_seconds,
    }
    accounted_seconds = sum(phases.values())
    ffmpeg_progress = _ffmpeg_progress(log_path)
    if metrics is not None:
        metrics["output"].update({
            "bytes": output_bytes,
            "duration_seconds": output_probe.duration_seconds,
            "has_audio": output_probe.has_audio,
            "container": output_probe.mime_guess,
            "average_bitrate_kbits_per_second": round(
                output_bytes * 8 / max(output_probe.duration_seconds, 0.001) / 1000, 3
            ),
        })
        metrics["ffmpeg"].update({
            "return_code": return_code,
            "reported_progress": ffmpeg_progress,
        })
        metrics.update({
            "phases_seconds": {key: round(value, 6) for key, value in phases.items()},
            "total_seconds": round(total_seconds, 6),
            "accounted_seconds": round(accounted_seconds, 6),
            "orchestration_and_progress_seconds": round(max(0.0, total_seconds - accounted_seconds), 6),
            "derived": {
                "capture_milliseconds_per_frame": round(capture_seconds * 1000 / count, 3),
                "capture_frames_per_second": round(count / max(capture_seconds, 0.000001), 3),
                "end_to_end_frames_per_second": round(count / max(total_seconds, 0.000001), 3),
                "video_seconds_per_render_second": round(probe.duration_seconds / max(total_seconds, 0.000001), 4),
                "capture_percent": round(capture_seconds / max(total_seconds, 0.000001) * 100, 2),
                "pipe_write_percent": round(pipe_write_seconds / max(total_seconds, 0.000001) * 100, 2),
                "encoder_drain_percent": round(encoder_drain_seconds / max(total_seconds, 0.000001) * 100, 2),
                "overlay_megapixels_per_second": round(
                    overlay_width * overlay_height * count / max(capture_seconds, 0.000001) / 1_000_000, 3
                ),
                "png_pipe_bytes": pipe_bytes,
                "average_png_bytes_per_frame": round(pipe_bytes / count, 3),
                "png_pipe_megabytes_per_second": round(
                    pipe_bytes / max(pipe_write_seconds + capture_seconds, 0.000001) / 1_000_000, 3
                ),
            },
        })
    logger.info(
        "render_timing frames=%d fps=%d output_bytes=%d preset=%s crf=%s "
        "browser_ready_s=%.3f scene_load_s=%.3f ffmpeg_start_s=%.3f "
        "frame_capture_and_decode_s=%.3f pipe_write_s=%.3f encoder_drain_s=%.3f "
        "output_probe_s=%.3f total_s=%.3f",
        count, FPS, output_bytes, preset, crf, browser_ready_seconds,
        scene_load_seconds, ffmpeg_start_seconds, capture_seconds,
        pipe_write_seconds, encoder_drain_seconds, output_probe_seconds,
        total_seconds,
    )
    return out_path

