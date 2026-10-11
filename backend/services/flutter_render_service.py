"""Render the very same Flutter scene used by the editor, then encode with FFmpeg.

No ASS translation or browser font substitution. The renderer is a private,
offline Flutter build. Only one transparent PNG frame is held in memory at a
time and frames are piped to FFmpeg; no video-sized frame directory is created.
"""
from __future__ import annotations

import base64
from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import subprocess
import threading

from services.ffmpeg_service import QUALITY_PRESETS, output_dimensions, probe_video
from services.render_scene import FPS, RENDERER_VERSION


class _QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


@contextmanager
def scene_browser(width, height):
    from playwright.sync_api import sync_playwright

    assets = Path(os.environ.get("CAPTION_RENDERER_DIR", "/opt/caption-renderer"))
    if not (assets / "main.dart.js").is_file():
        raise RuntimeError("Shared caption renderer is not built. Rebuild the worker image.")
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(_QuietHandler, directory=str(assets)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    origin = f"http://127.0.0.1:{server.server_port}"
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=True, executable_path="/usr/bin/chromium",
                args=["--disable-dev-shm-usage", "--use-angle=swiftshader"])
            try:
                page = browser.new_page(viewport={"width": width, "height": height}, device_scale_factor=1)
                # Transcript data stays local; no CDN/font/network requests are allowed.
                page.route("**/*", lambda route: route.continue_()
                    if route.request.url.startswith(origin + "/") else route.abort())
                page.goto(origin, wait_until="load")
                page.wait_for_function("window.captionReady === true", timeout=60000)
                yield page
            finally:
                browser.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def load_scene(page, snapshot):
    if snapshot.get("renderer_version") != RENDERER_VERSION:
        raise ValueError("Caption renderer version changed. Please render again.")
    page.evaluate("scene => window.captionLoad(scene)", json.dumps(snapshot, ensure_ascii=False))


def capture_frame(page, time):
    return base64.b64decode(page.evaluate("t => window.captionFrame(t)", time), validate=True)


def render_scene(video_path: Path, snapshot: dict, out_path: Path,
                 quality="standard", progress=None) -> Path:
    probe = probe_video(video_path)
    width, height = output_dimensions(probe.width, probe.height, snapshot["aspect_ratio"])
    q = QUALITY_PRESETS.get(quality, QUALITY_PRESETS["standard"])
    count = max(1, math.ceil(probe.duration_seconds * FPS))
    # Always normalize source pixels and contain/pad before compositing. Caption
    # coordinates are in the output canvas, including its letterboxing.
    graph = (f"[0:v]scale=trunc(iw*sar/2)*2:ih,setsar=1,scale={width}:{height}:force_original_aspect_ratio=decrease:"
             f"force_divisible_by=2,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,"
             f"setsar=1,fps={FPS},setpts=PTS-STARTPTS[video];"
             "[video][1:v]overlay=0:0:format=auto:shortest=1,format=yuv420p[out]")
    cmd = ["ffmpeg", "-y", "-i", str(video_path), "-f", "image2pipe", "-vcodec", "png",
           "-framerate", str(FPS), "-i", "pipe:0", "-filter_complex_threads", "1",
           "-filter_complex", graph, "-map", "[out]", "-map", "0:a?",
           "-c:v", "libx264", "-preset", q["preset"], "-crf", q["crf"],
           "-c:a", "aac", "-b:a", "128k", "-t", str(probe.duration_seconds),
           "-movflags", "+faststart", str(out_path)]
    with scene_browser(width, height) as page, (out_path.parent / "render.log").open("wb") as log:
        load_scene(page, snapshot)
        process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=log)
        try:
            for frame in range(count):
                if progress and frame % FPS == 0:
                    progress(frame / count)
                process.stdin.write(capture_frame(page, frame / FPS))
            process.stdin.close()
            if process.wait(timeout=120) != 0:
                raise RuntimeError("Video encoding failed; see the worker render log.")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if not process.stdin.closed:
                process.stdin.close()
    if not out_path.is_file() or out_path.stat().st_size <= 0:
        raise RuntimeError("Video encoding produced no output file.")
    output_probe = probe_video(out_path)
    if output_probe.width != width or output_probe.height != height:
        raise RuntimeError("Rendered video dimensions did not match the requested output.")
    if abs(output_probe.duration_seconds - probe.duration_seconds) > max(0.5, 2 / FPS):
        raise RuntimeError("Rendered video duration did not match the source video.")
    if output_probe.has_audio != probe.has_audio:
        raise RuntimeError("Rendered video audio track did not match the source video.")
    return out_path
