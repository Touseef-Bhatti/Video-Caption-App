"""Benchmark the production software composite with 1, 2, and 4 threads.

Run: python scripts/bench_composite.py source.mp4 caption-overlay.mkv --repeats 3
The overlay should be the alpha-bearing caption overlay produced by a render.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from app.config import get_settings
from services.ffmpeg_service import probe_video
from services.flutter_render_service import _composite_command


def _rss_bytes(process: subprocess.Popen) -> int | None:
    """Read FFmpeg's peak resident memory on Linux or Windows."""
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                        ("PeakWorkingSetSize", ctypes.c_size_t),
                        ("WorkingSetSize", ctypes.c_size_t),
                        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                        ("PagefileUsage", ctypes.c_size_t),
                        ("PeakPagefileUsage", ctypes.c_size_t)]

        counters = Counters()
        counters.cb = ctypes.sizeof(Counters)
        handle = wintypes.HANDLE(int(process._handle))
        if ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
            return int(counters.PeakWorkingSetSize)
        return None
    if sys.platform.startswith("linux"):
        try:
            for line in Path(f"/proc/{process.pid}/status").read_text().splitlines():
                if line.startswith("VmHWM:"):
                    return int(line.split()[1]) * 1024
        except OSError:
            pass
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("overlay", type=Path)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--json", type=Path, help="also write the results to this file")
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")
    source, overlay = args.source.resolve(), args.overlay.resolve()
    if not source.is_file() or not overlay.is_file():
        parser.error("source and overlay must both exist")
    probe = probe_video(source)
    width, height = probe.width, probe.height
    graph = (f"[0:v]scale={width}:{height}:flags=lanczos,setsar=1,setpts=PTS-STARTPTS[video];"
             f"[1:v]scale={width}:{height}:flags=lanczos,format=rgba[caption];"
             "[video][caption]overlay=0:0:eof_action=repeat:repeatlast=1:"
             "shortest=0:format=auto,format=yuv420p[out]")
    results = []
    # The composite needs encoder settings but no database, API, or Gemini access.
    os.environ.setdefault("JWT_SECRET", "benchmark-local-only")
    os.environ.setdefault("DATABASE_URL", "sqlite:///benchmark-unused")
    os.environ.setdefault("GEMINI_API_KEY", "benchmark-local-only")
    os.environ["CAPTION_VIDEO_ENCODER"] = "libx264"
    with tempfile.TemporaryDirectory(prefix="bench_composite_") as temporary:
        for threads in (1, 2, 4):
            os.environ["FFMPEG_THREADS"] = str(threads)
            os.environ["FFMPEG_FILTER_THREADS"] = str(threads)
            get_settings.cache_clear()
            for repeat in range(1, args.repeats + 1):
                output = Path(temporary) / f"threads_{threads}_repeat_{repeat}.mp4"
                cmd, _ = _composite_command(source, overlay, output, graph,
                                            probe.duration_seconds, width, height,
                                            probe.frame_rate or 30)
                started = time.perf_counter()
                with (Path(temporary) / "ffmpeg.log").open("wb") as log:
                    process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=log)
                    max_rss = 0
                    while True:
                        rss = _rss_bytes(process)
                        if rss is not None:
                            max_rss = max(max_rss, rss)
                        try:
                            return_code = process.wait(timeout=0.05)
                            break
                        except subprocess.TimeoutExpired:
                            pass
                wall = time.perf_counter() - started
                if return_code:
                    error = (Path(temporary) / "ffmpeg.log").read_text(errors="replace")
                    raise RuntimeError(f"FFmpeg failed for {threads} threads, repeat {repeat}: {error[-2000:]}")
                rendered = probe_video(output)
                results.append({"threads": threads, "repeat": repeat,
                                "wall_seconds": round(wall, 6),
                                "fps": round(rendered.duration_seconds * (rendered.frame_rate or 0) / wall, 3),
                                "max_rss_bytes": max_rss or None,
                                "output_bytes": output.stat().st_size})
                output.unlink()
    report = {"source": str(source), "overlay": str(overlay), "repeats": args.repeats,
              "results": results}
    encoded = json.dumps(report, indent=2)
    if args.json:
        args.json.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)


if __name__ == "__main__":
    main()
