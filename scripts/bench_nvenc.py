"""Compare NVENC CQ and preset combinations for one source/overlay pair.

Run on an NVIDIA worker:
    python scripts/bench_nvenc.py source.mp4 caption-overlay.mkv

The script prints JSON measurements; it does not assess visual quality.
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("overlay", type=Path)
    parser.add_argument("--json", type=Path, help="also write results to this file")
    args = parser.parse_args()
    source, overlay = args.source.resolve(), args.overlay.resolve()
    if not source.is_file() or not overlay.is_file():
        parser.error("source and overlay must both exist")

    os.environ.setdefault("JWT_SECRET", "benchmark-local-only")
    os.environ.setdefault("DATABASE_URL", "sqlite:///benchmark-unused")
    os.environ.setdefault("GEMINI_API_KEY", "benchmark-local-only")
    os.environ["CAPTION_VIDEO_ENCODER"] = "h264_nvenc"
    get_settings.cache_clear()

    probe = probe_video(source)
    width, height = probe.width, probe.height
    graph = (
        f"[0:v]scale={width}:{height}:flags=lanczos,setsar=1,setpts=PTS-STARTPTS[video];"
        f"[1:v]scale={width}:{height}:flags=lanczos,format=rgba[caption];"
        "[video][caption]overlay=0:0:eof_action=repeat:repeatlast=1:"
        "shortest=0:format=auto,format=yuv420p[out]"
    )
    results = []
    with tempfile.TemporaryDirectory(prefix="bench_nvenc_") as temporary:
        temp = Path(temporary)
        for cq in (26, 28, 30):
            for preset in ("p4", "p5"):
                output = temp / f"cq_{cq}_{preset}.mp4"
                command, _ = _composite_command(
                    source, overlay, output, graph, probe.duration_seconds,
                    width, height, probe.frame_rate or 30, quality="standard",
                    source_video_bitrate_bps=probe.bit_rate,
                    nvenc_preset=preset, nvenc_cq=cq,
                )
                started = time.perf_counter()
                completed = subprocess.run(command, capture_output=True, text=True)
                elapsed = time.perf_counter() - started
                if completed.returncode:
                    raise RuntimeError(
                        f"NVENC failed for CQ {cq}, preset {preset}: "
                        f"{completed.stderr[-2000:]}"
                    )
                rendered = probe_video(output)
                output_bytes = output.stat().st_size
                results.append({
                    "cq": cq,
                    "preset": preset,
                    "output_bytes": output_bytes,
                    "output_megabytes": round(output_bytes / 1_000_000, 3),
                    "average_bitrate_kbits_per_second": round(
                        output_bytes * 8 / max(rendered.duration_seconds, 0.001) / 1000, 3
                    ),
                    "video_bitrate_bps": rendered.bit_rate,
                    "fps": round(
                        rendered.duration_seconds * (rendered.frame_rate or 0)
                        / max(elapsed, 0.000001), 3
                    ),
                    "elapsed_seconds": round(elapsed, 4),
                })
                output.unlink()

    report = {
        "source": str(source),
        "overlay": str(overlay),
        "source_video_bitrate_bps": probe.bit_rate,
        "output_resolution": {"width": width, "height": height},
        "results": results,
    }
    encoded = json.dumps(report, indent=2)
    if args.json:
        args.json.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)


if __name__ == "__main__":
    main()
