"""Render the editor's Flutter scene with parallel frame-aligned chunks.

No ASS translation or browser font substitution. The private offline Flutter
build captures 10-second ranges in up to four Chromium workers; ordered FFmpeg
concat and source-video compositing keep the final output continuous.
"""
from __future__ import annotations

import atexit
import base64
from concurrent.futures import ThreadPoolExecutor, as_completed
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
from services.render_scene import FPS, RENDERER_VERSION, RENDER_PIPELINE_VERSION
from services.video_encoder import encoder_options

logger = logging.getLogger(__name__)
RENDER_CHUNK_SECONDS = 10
RENDER_WORKERS = 4


class _QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


class _SceneRuntime:
    """Keep one warm Flutter page and Chromium instance per render thread."""

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
        bundled_roboto = next(assets.rglob("Roboto-Variable.ttf"), None)

        def fulfill_local_font(route):
            request_url = urlparse(route.request.url)
            if (request_url.hostname == "fonts.gstatic.com"
                    and request_url.path.startswith("/s/roboto/")):
                if bundled_roboto is None or not bundled_roboto.is_file():
                    logger.error("Bundled Roboto font is missing from the renderer image.")
                    route.abort()
                    return
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


_scene_runtimes: list[_SceneRuntime] = []
_scene_runtimes_lock = threading.Lock()
_scene_runtime_local = threading.local()


def _close_scene_runtimes():
    with _scene_runtimes_lock:
        runtimes = list(_scene_runtimes)
        _scene_runtimes.clear()
    for runtime in runtimes:
        runtime.close()


atexit.register(_close_scene_runtimes)


@contextmanager
def scene_browser(width, height):
    runtime = getattr(_scene_runtime_local, "runtime", None)
    if runtime is None:
        runtime = _SceneRuntime()
        _scene_runtime_local.runtime = runtime
        with _scene_runtimes_lock:
            _scene_runtimes.append(runtime)
    with runtime.use(width, height) as page:
        yield page


def _capture_overlay_chunk(snapshot: dict, overlay_width: int, overlay_height: int,
                           canvas_scale: float, start_frame: int, end_frame: int,
                           overlay_path: Path, log_path: Path) -> dict:
    """Capture one frame-aligned time range in its own Chromium worker."""
    started = time.perf_counter()
    overlay_cmd = ["ffmpeg", "-y", "-f", "image2pipe", "-vcodec", "png",
                   "-framerate", str(FPS), "-i", "pipe:0", "-an", "-c:v", "ffv1",
                   "-pix_fmt", "bgra", "-threads", "1", str(overlay_path)]
    capture_seconds = 0.0
    pipe_write_seconds = 0.0
    pipe_bytes = 0
    browser_ready_seconds = 0.0
    scene_load_seconds = 0.0
    ffmpeg_start_seconds = 0.0
    encoder_drain_seconds = 0.0
    process = None
    try:
        browser_started = time.perf_counter()
        with scene_browser(overlay_width, overlay_height) as page, log_path.open("wb") as log:
            browser_ready_seconds = time.perf_counter() - browser_started
            scene_started = time.perf_counter()
            load_scene(page, snapshot, canvas_scale)
            scene_load_seconds = time.perf_counter() - scene_started
            ffmpeg_started = time.perf_counter()
            process = subprocess.Popen(overlay_cmd, stdin=subprocess.PIPE,
                                       stdout=subprocess.DEVNULL, stderr=log)
            ffmpeg_start_seconds = time.perf_counter() - ffmpeg_started
            for frame in range(start_frame, end_frame):
                capture_started = time.perf_counter()
                frame_bytes = capture_frames(page, frame, 1)[0]
                capture_seconds += time.perf_counter() - capture_started
                pipe_bytes += len(frame_bytes)
                write_started = time.perf_counter()
                process.stdin.write(frame_bytes)
                pipe_write_seconds += time.perf_counter() - write_started
            process.stdin.close()
            drain_started = time.perf_counter()
            return_code = process.wait(timeout=max(120, (end_frame - start_frame) / FPS * 2))
            encoder_drain_seconds = time.perf_counter() - drain_started
            if return_code != 0:
                raise RuntimeError(f"Caption overlay chunk {start_frame} failed to encode.")
        return {
            "start_frame": start_frame,
            "end_frame": end_frame,
            "frame_count": end_frame - start_frame,
            "start_seconds": round(start_frame / FPS, 6),
            "end_seconds": round(end_frame / FPS, 6),
            "browser_ready_seconds": browser_ready_seconds,
            "scene_load_seconds": scene_load_seconds,
            "ffmpeg_start_seconds": ffmpeg_start_seconds,
            "capture_seconds": capture_seconds,
            "pipe_write_seconds": pipe_write_seconds,
            "encoder_drain_seconds": encoder_drain_seconds,
            "total_seconds": time.perf_counter() - started,
            "png_bytes": pipe_bytes,
            "overlay_path": str(overlay_path),
        }
    except Exception:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        raise


def _capture_overlay_worker(snapshot: dict, overlay_width: int, overlay_height: int,
                            canvas_scale: float, worker_index: int,
                            chunks: list[tuple[int, int, Path, Path]]) -> list[dict]:
    """Reuse one Chromium instance while this worker renders its assigned chunks."""
    results = []
    try:
        for start_frame, end_frame, overlay_path, log_path in chunks:
            result = _capture_overlay_chunk(
                snapshot, overlay_width, overlay_height, canvas_scale,
                start_frame, end_frame, overlay_path, log_path,
            )
            result["worker_index"] = worker_index
            results.append(result)
        return results
    finally:
        runtime = getattr(_scene_runtime_local, "runtime", None)
        if runtime is not None:
            runtime.close()
            _scene_runtime_local.runtime = None
            with _scene_runtimes_lock:
                if runtime in _scene_runtimes:
                    _scene_runtimes.remove(runtime)


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
                 output_resolution=0, output_fps=0,
                 encoder_preset=None, encoder_crf=None,
                 metrics: dict | None = None) -> Path:
    probe = probe or probe_video(video_path)
    output_resolution = output_resolution or 0
    output_fps = output_fps or probe.frame_rate or 30
    width, height = output_dimensions(
        probe.width, probe.height, snapshot["aspect_ratio"], output_resolution)
    overlay_width, overlay_height = _overlay_dimensions(width, height)
    q = QUALITY_PRESETS.get(quality, QUALITY_PRESETS["standard"])
    preset = encoder_preset or q["preset"]
    crf = encoder_crf or q["crf"]
    video_codec, video_encoder_args = encoder_options(quality, preset, crf)
    encoder_threads = int(os.environ.get("CAPTION_ENCODER_THREADS", "1"))
    filter_threads = int(os.environ.get("CAPTION_FILTER_THREADS", "1"))
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
    cmd = ["ffmpeg", "-y", "-threads", "1", "-i", str(video_path), "-i", str(overlay_path),
           "-filter_complex_threads", str(filter_threads), "-filter_complex", graph, "-map", "[out]",
           "-map", "0:a?", "-fps_mode", "passthrough", *video_encoder_args,
           "-threads", str(encoder_threads), "-c:a", "copy",
           "-t", str(probe.duration_seconds), "-movflags", "+faststart",
           str(out_path)]
    sanitized_cmd = _sanitized_command(cmd, video_path, out_path)
    if metrics is not None:
        metrics.update({
            "schema_version": 1,
            "renderer_version": RENDERER_VERSION,
            "render_pipeline_version": RENDER_PIPELINE_VERSION,
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
                       "frame_rate": output_fps,
                       "requested_max_dimension": output_resolution},
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
                "filter_complex_threads": filter_threads,
                "overlay_input_format": "ffv1/matroska/bgra",
                "video_codec": video_codec,
                "preset": preset if video_codec == "libx264" else ("p6" if quality == "high" else "p4"),
                "crf": crf if video_codec == "libx264" else None,
                "cq": crf if video_codec == "h264_nvenc" else None,
                "pixel_format": "yuv420p",
                "encoder_threads": encoder_threads,
                "audio_codec": "copy_source",
                "movflags": "+faststart",
            },
        })
    render_started = time.perf_counter()
    log_path = out_path.parent / "render.log"
    chunk_frames = RENDER_CHUNK_SECONDS * FPS
    frame_ranges = [(start, min(start + chunk_frames, count))
                    for start in range(0, count, chunk_frames)]
    chunk_dir = out_path.with_name(out_path.stem + ".caption_chunks")
    chunk_dir.mkdir(parents=True, exist_ok=True)
    chunk_paths = [chunk_dir / f"overlay_{index:06d}.mkv"
                   for index in range(len(frame_ranges))]
    chunk_logs = [chunk_dir / f"overlay_{index:06d}.log"
                  for index in range(len(frame_ranges))]
    worker_count = min(RENDER_WORKERS, len(frame_ranges))
    worker_chunks = [[] for _ in range(worker_count)]
    for index, (start, end) in enumerate(frame_ranges):
        worker_chunks[index % worker_count].append(
            (start, end, chunk_paths[index], chunk_logs[index]))
    capture_wall_started = time.perf_counter()
    chunk_results = []
    try:
        if progress:
            progress(0.02)
        with ThreadPoolExecutor(max_workers=worker_count) as pool:
            futures = [
                pool.submit(
                    _capture_overlay_worker, snapshot, overlay_width, overlay_height,
                    overlay_width / width, worker_index, assignments,
                )
                for worker_index, assignments in enumerate(worker_chunks)
            ]
            finished_chunks = 0
            for future in as_completed(futures):
                results = future.result()
                chunk_results.extend(results)
                finished_chunks += len(results)
                if progress:
                    progress(0.02 + 0.78 * finished_chunks / len(frame_ranges))
        capture_wall_seconds = time.perf_counter() - capture_wall_started
        chunk_results.sort(key=lambda item: item["start_frame"])
        for index, result in enumerate(chunk_results):
            result["chunk_index"] = index

        # The concat manifest is written in chunk-index order, independent of
        # the order workers finish. Every chunk contains the exact assigned
        # frame interval and keeps the animation clock on the global timeline.
        concat_manifest = chunk_dir / "overlays.ffconcat"
        def concat_entry(path: Path) -> str:
            escaped = path.resolve().as_posix().replace("'", "'\\''")
            return f"file '{escaped}'"
        concat_manifest.write_text(
            "ffconcat version 1.0\n" + "\n".join(concat_entry(path) for path in chunk_paths) + "\n",
            encoding="utf-8",
        )
        merge_started = time.perf_counter()
        merge_result = subprocess.run(
            ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat_manifest),
             "-c", "copy", str(overlay_path)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            timeout=max(120, probe.duration_seconds * 2),
        )
        if merge_result.returncode != 0:
            logger.error("Caption overlay chunk merge failed: %s", merge_result.stderr[-4000:])
            raise RuntimeError("Caption overlay chunks could not be merged in order.")
        chunk_merge_seconds = time.perf_counter() - merge_started
    finally:
        for path in chunk_paths + chunk_logs:
            path.unlink(missing_ok=True)
        (chunk_dir / "overlays.ffconcat").unlink(missing_ok=True)
        try:
            chunk_dir.rmdir()
        except OSError:
            logger.warning("Could not remove temporary caption chunk directory: %s", chunk_dir.name)

    capture_seconds = sum(chunk["capture_seconds"] for chunk in chunk_results)
    pipe_write_seconds = sum(chunk["pipe_write_seconds"] for chunk in chunk_results)
    encoder_drain_seconds = sum(chunk["encoder_drain_seconds"] for chunk in chunk_results)
    pipe_bytes = sum(chunk["png_bytes"] for chunk in chunk_results)
    browser_ready_seconds = max(chunk["browser_ready_seconds"] for chunk in chunk_results)
    scene_load_seconds = max(chunk["scene_load_seconds"] for chunk in chunk_results)
    ffmpeg_start_seconds = max(chunk["ffmpeg_start_seconds"] for chunk in chunk_results)
    composite_started = time.perf_counter()
    with log_path.open("wb") as log:
        composite_result = subprocess.run(
            cmd, stdout=subprocess.DEVNULL, stderr=log,
            timeout=max(180, probe.duration_seconds * 3),
        )
    return_code = composite_result.returncode
    if return_code != 0:
        raise RuntimeError("Video compositing failed; see the worker render log.")
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
    if (output_probe.frame_rate and probe.frame_rate
            and abs(output_probe.frame_rate - probe.frame_rate) > max(0.02, probe.frame_rate * 0.005)):
        raise RuntimeError("Rendered video frame rate did not match the source video.")
    total_seconds = time.perf_counter() - render_started
    phases = {
        "parallel_overlay_generation": capture_wall_seconds,
        "overlay_chunk_merge": chunk_merge_seconds,
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
            "chunking": {
                "chunk_duration_seconds": RENDER_CHUNK_SECONDS,
                "parallel_workers": worker_count,
                "boundary_unit": "caption_frame",
                "caption_fps": FPS,
                "animation_timestamps": "global_frame_index",
                "caption_timing": "global frame time rendered into each chunk-local frame",
                "merge_order": "chunk_index",
                "wall_seconds": round(capture_wall_seconds, 6),
                "worker_capture_seconds_sum": round(capture_seconds, 6),
                "worker_pipe_write_seconds_sum": round(pipe_write_seconds, 6),
                "worker_encoder_drain_seconds_sum": round(encoder_drain_seconds, 6),
                "worker_startup_seconds_max": round(browser_ready_seconds, 6),
                "scene_load_seconds_max": round(scene_load_seconds, 6),
                "ffmpeg_start_seconds_max": round(ffmpeg_start_seconds, 6),
                "png_bytes": pipe_bytes,
                "chunks": [
                    {key: value for key, value in chunk.items() if key != "overlay_path"}
                    for chunk in chunk_results
                ],
            },
            "derived": {
                "capture_milliseconds_per_frame": round(capture_seconds * 1000 / count, 3),
                "capture_frames_per_second": round(count / max(capture_wall_seconds, 0.000001), 3),
                "end_to_end_frames_per_second": round(count / max(total_seconds, 0.000001), 3),
                "video_seconds_per_render_second": round(probe.duration_seconds / max(total_seconds, 0.000001), 4),
                "capture_percent": round(capture_wall_seconds / max(total_seconds, 0.000001) * 100, 2),
                "pipe_write_percent_of_aggregate_worker_time": round(pipe_write_seconds / max(capture_seconds + pipe_write_seconds + encoder_drain_seconds, 0.000001) * 100, 2),
                "encoder_drain_percent_of_aggregate_worker_time": round(encoder_drain_seconds / max(capture_seconds + pipe_write_seconds + encoder_drain_seconds, 0.000001) * 100, 2),
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
        "parallel_workers=%d chunks=%d chunk_capture_wall_s=%.3f "
        "frame_capture_worker_s=%.3f pipe_write_worker_s=%.3f overlay_merge_s=%.3f "
        "output_probe_s=%.3f total_s=%.3f",
        count, FPS, output_bytes, preset, crf,
        worker_count, len(frame_ranges), capture_wall_seconds, capture_seconds, pipe_write_seconds,
        chunk_merge_seconds, output_probe_seconds,
        total_seconds,
    )
    return out_path
