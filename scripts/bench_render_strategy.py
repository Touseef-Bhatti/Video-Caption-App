"""Render the same source and snapshot with both capture strategies.

Run after building the private renderer:
  python scripts/bench_render_strategy.py source.mp4 snapshot.json --repeats 3

Writes one JSON report per run using the performance test page's top-level
fields and its rerender.server_diagnostics.render shape. No API is required.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from app.config import get_settings
from services.ffmpeg_service import probe_video
from services.flutter_render_service import render_scene


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("snapshot", type=Path,
                        help="JSON render snapshot containing caption_data and style_preset")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output-dir", type=Path, default=Path("strategy-bench-reports"))
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")
    source = args.source.resolve()
    snapshot_path = args.snapshot.resolve()
    if not source.is_file() or not snapshot_path.is_file():
        parser.error("source and snapshot must both exist")
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    for key in ("renderer_version", "caption_data", "style_preset", "aspect_ratio"):
        if key not in snapshot:
            parser.error(f"snapshot is missing {key}")
    os.environ.setdefault("JWT_SECRET", "benchmark-local-only")
    os.environ.setdefault("DATABASE_URL", "sqlite:///benchmark-unused")
    os.environ.setdefault("GEMINI_API_KEY", "benchmark-local-only")
    os.environ.setdefault("CAPTION_RENDERER_DIR", str(ROOT / "frontend/build/renderer"))
    if os.name == "nt":
        chrome = Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe")
        if chrome.is_file():
            os.environ.setdefault("CAPTION_CHROMIUM_EXECUTABLE", str(chrome))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    source_probe = probe_video(source)
    for repeat in range(1, args.repeats + 1):
        for strategy in ("legacy", "adaptive"):
            os.environ["CAPTION_RENDER_STRATEGY"] = strategy
            get_settings.cache_clear()
            run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            started_at = utc_now()
            started = time.perf_counter()
            metrics = {}
            status = "completed"
            failure = None
            with tempfile.TemporaryDirectory(prefix="caption_strategy_bench_") as temp:
                output = Path(temp) / "output.mp4"
                try:
                    render_scene(source, snapshot, output, probe=source_probe,
                                 metrics=metrics)
                except Exception as exc:
                    status = "failed"
                    failure = {"message": str(exc), "type": type(exc).__name__}
                elapsed = time.perf_counter() - started
                report = {
                    "run_id": run_id,
                    "started_at_utc": started_at,
                    "finished_at_utc": utc_now(),
                    "api_origin": "local-render-benchmark",
                    "input": {"file_name": source.name, "file_size_bytes": source.stat().st_size,
                              "width": source_probe.width, "height": source_probe.height,
                              "duration_seconds": source_probe.duration_seconds},
                    "settings": {"caption_render_strategy": strategy,
                                 "render_quality": "standard",
                                 "aspect_ratio": snapshot["aspect_ratio"],
                                 "snapshot_file": str(snapshot_path), "repeat": repeat},
                    "requests": [], "upload_chunks": [], "events": [],
                    "processing": {},
                    "rerender": {"final_status": status,
                                 "elapsed_seconds": round(elapsed, 6),
                                 "server_diagnostics": {
                                     "schema_version": 3,
                                     "job_type": "edited_rerender",
                                     "render": metrics}},
                    "resources": {"samples": []},
                    "exports": ([{"output_bytes": output.stat().st_size}]
                                if output.is_file() else []),
                    "total_elapsed_seconds": round(elapsed, 6),
                }
                if failure:
                    report["failure"] = failure
                target = args.output_dir / f"caption-pipeline-{run_id}-{strategy}.json"
                target.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
                print(target)
                if failure:
                    raise RuntimeError(f"{strategy} render failed: {failure['message']}")


if __name__ == "__main__":
    main()
