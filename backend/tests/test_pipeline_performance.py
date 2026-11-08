"""Opt-in end-to-end performance run for upload, caption edit, save, and render.

Run from the repository root (PowerShell):

  $env:PERF_API_URL = 'http://localhost:8000'
  $env:PERF_BEARER_TOKEN = '<a valid API access token>'
  $env:PERF_VIDEO_PATH = 'D:\\media\\sample.mp4'
  $env:PERF_REPORT_DIR = 'backend\\perf-reports'
  .venv\\Scripts\\python -m pytest backend\\tests\\test_pipeline_performance.py -s

This intentionally uses a real backend, worker, storage, Gemini account, and
FFmpeg renderer. It creates a new project and stores a JSON report plus a
human-readable Markdown summary. The one edit is a small suffix added to the
first caption word/line. Do not point it at a production account unless a test
project and its generated export are acceptable.
"""
from __future__ import annotations

import copy
import json
import mimetypes
import os
import shutil
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
import pytest


API_URL = os.getenv("PERF_API_URL", "http://localhost:8000").rstrip("/")
TOKEN = os.getenv("PERF_BEARER_TOKEN", "")
VIDEO_PATH = Path(os.getenv("PERF_VIDEO_PATH", ""))
POLL_SECONDS = max(0.25, float(os.getenv("PERF_POLL_SECONDS", "1")))
TIMEOUT_SECONDS = max(60, int(os.getenv("PERF_TIMEOUT_SECONDS", "7200")))
REPORT_DIR = Path(os.getenv("PERF_REPORT_DIR", "backend/perf-reports"))

pytestmark = pytest.mark.skipif(
    not TOKEN or not str(VIDEO_PATH) or not VIDEO_PATH.is_file(),
    reason="Set PERF_BEARER_TOKEN and PERF_VIDEO_PATH to run the live pipeline benchmark",
)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _json_response(response: httpx.Response) -> Any:
    response.raise_for_status()
    return response.json() if response.content else None


def _timed_request(report: dict, name: str, method: str, url: str, **kwargs) -> httpx.Response:
    started_at = _utc_now()
    started = time.perf_counter()
    response = httpx.request(method, url, timeout=None, **kwargs)
    elapsed = time.perf_counter() - started
    report["requests"].append({
        "name": name,
        "method": method,
        "path": url.removeprefix(API_URL),
        "elapsed_seconds": round(elapsed, 4),
        "status_code": response.status_code,
        "request_bytes": int(response.request.headers.get("content-length", 0) or 0),
        "response_bytes": len(response.content),
        "started_at_utc": started_at,
    })
    return response


def _probe_input(path: Path) -> dict:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return {"available": False, "error": "ffprobe was not found on PATH"}
    started = time.perf_counter()
    result = subprocess.run(
        [ffprobe, "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(path)],
        capture_output=True, text=True, check=False,
    )
    elapsed = time.perf_counter() - started
    if result.returncode:
        return {"available": True, "elapsed_seconds": round(elapsed, 4), "error": result.stderr[-2000:]}
    data = json.loads(result.stdout)
    video = next((s for s in data.get("streams", []) if s.get("codec_type") == "video"), {})
    audio = next((s for s in data.get("streams", []) if s.get("codec_type") == "audio"), {})
    return {
        "available": True,
        "probe_elapsed_seconds": round(elapsed, 4),
        "duration_seconds": float(data.get("format", {}).get("duration") or video.get("duration") or 0),
        "file_size_bytes": path.stat().st_size,
        "container": data.get("format", {}).get("format_name"),
        "video_codec": video.get("codec_name"),
        "audio_codec": audio.get("codec_name"),
        "width": video.get("width"),
        "height": video.get("height"),
        "frame_rate": video.get("avg_frame_rate"),
        "video_bitrate": video.get("bit_rate"),
        "audio_sample_rate": audio.get("sample_rate"),
        "audio_channels": audio.get("channels"),
        "has_audio": bool(audio),
    }


class _DockerStats:
    """Optional live CPU/memory sampling for local Docker app/worker containers."""

    def __init__(self, interval: float = 1.0):
        self.interval = interval
        self.samples: list[dict] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.available = bool(shutil.which("docker"))

    def start(self) -> None:
        if not self.available:
            return
        self._thread = threading.Thread(target=self._collect, name="pipeline-docker-stats", daemon=True)
        self._thread.start()

    def _collect(self) -> None:
        while not self._stop.is_set():
            try:
                proc = subprocess.run(
                    ["docker", "stats", "--no-stream", "--format", "{{json .}}"],
                    capture_output=True, text=True, timeout=8, check=False,
                )
                if proc.returncode == 0:
                    for line in proc.stdout.splitlines():
                        try:
                            item = json.loads(line)
                            self.samples.append({"at_utc": _utc_now(), **item})
                        except json.JSONDecodeError:
                            continue
            except (OSError, subprocess.TimeoutExpired):
                self.available = False
                return
            self._stop.wait(self.interval)

    def stop(self) -> list[dict]:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=10)
        return self.samples


def _stage_durations(observations: list[dict]) -> list[dict]:
    """Compute observed stage windows; boundaries are limited by the poll interval."""
    rows: list[dict] = []
    if len(observations) < 2:
        return rows
    stage = observations[0]["stage"]
    status = observations[0]["status"]
    started = observations[0]["elapsed_seconds"]
    for current in observations[1:]:
        if current["stage"] != stage:
            rows.append({
                "stage": stage,
                "status": status,
                "observed_seconds": round(current["elapsed_seconds"] - started, 3),
            })
            stage = current["stage"]
            status = current["status"]
            started = current["elapsed_seconds"]
    return rows


def _docker_resource_summary(samples: list[dict]) -> dict:
    summary: dict[str, dict] = {}
    for sample in samples:
        name = sample.get("Name") or sample.get("name") or "unknown"
        item = summary.setdefault(name, {"samples": 0, "peak_cpu_percent": None, "latest_memory_usage": None})
        item["samples"] += 1
        cpu = str(sample.get("CPUPerc", "")).rstrip("%")
        try:
            cpu_value = float(cpu)
            item["peak_cpu_percent"] = max(item["peak_cpu_percent"] or 0, cpu_value)
        except ValueError:
            pass
        memory = str(sample.get("MemUsage", ""))
        if memory:
            item["latest_memory_usage"] = memory
    return summary


def _edit_one_caption(caption: dict) -> tuple[dict, dict]:
    edited = copy.deepcopy(caption["caption_data"])
    segments = edited.get("segments") or []
    if not segments:
        raise AssertionError("The completed transcription has no caption segments to edit")
    segment = segments[0]
    words = segment.get("words") or []
    if words:
        old = str(words[0].get("text", ""))
        new = f"{old} (edited)"
        words[0]["text"] = new
        line = str(segment.get("text", ""))
        segment["text"] = line.replace(old, new, 1) if old and old in line else f"{line} (edited)"
        change = {"type": "caption_text", "location": "segments[0].words[0]", "before": old, "after": new}
    else:
        old = str(segment.get("text", ""))
        new = f"{old} (edited)"
        segment["text"] = new
        change = {"type": "caption_text", "location": "segments[0].text", "before": old, "after": new}
    return edited, change


def _write_reports(report: dict) -> tuple[Path, Path]:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    json_path = REPORT_DIR / f"pipeline-performance-{stamp}.json"
    md_path = REPORT_DIR / f"pipeline-performance-{stamp}.md"
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    lines = [
        "# Video caption pipeline performance report", "",
        f"- Run: `{report['run_id']}`", f"- API: `{report['api_url']}`",
        f"- Started (UTC): {report['started_at_utc']}",
        f"- Total wall time: {report.get('total_elapsed_seconds', 'incomplete')} seconds",
        f"- Input: `{report['input']['file_name']}` ({report['input']['file_size_bytes']} bytes)",
        f"- Video duration: {report['input'].get('duration_seconds', 'unknown')} seconds",
        f"- Settings: caption language `{report['settings']['caption_language']}`, preset `{report.get('initial_caption', {}).get('style_preset', 'classic')}`, export quality `standard`, aspect ratio `original`", "",
        "## Observed worker stages", "",
        "Times are wall-clock estimates from polling `/api/jobs`; boundary uncertainty is up to the configured polling interval.", "",
        "| Stage | Status | Observed seconds |", "|---|---|---:|",
    ]
    for row in report.get("processing", {}).get("stage_durations", []):
        lines.append(f"| {row['stage']} | {row['status']} | {row['observed_seconds']:.3f} |")
    lines.extend(["", "## Client operations", "", "| Operation | Seconds | HTTP | Bytes sent | Bytes received |", "|---|---:|---:|---:|---:|"])
    for row in report.get("requests", []):
        lines.append(f"| {row['name']} | {row['elapsed_seconds']:.3f} | {row['status_code']} | {row['request_bytes']} | {row['response_bytes']} |")
    if report.get("upload_chunks"):
        lines.extend(["", "## Upload chunk timings", "", "| Chunk | Bytes | Seconds | Throughput Mbps |", "|---:|---:|---:|---:|"])
        for row in report["upload_chunks"]:
            lines.append(f"| {row['chunk_index']} | {row['bytes']} | {row['elapsed_seconds']:.3f} | {row['throughput_mbps']:.3f} |")
    lines.extend([
        "", "## Render and resource details", "",
        f"- Initial processing: `{report.get('processing', {}).get('final_status', 'incomplete')}`",
        f"- Re-render: `{report.get('rerender', {}).get('final_status', 'incomplete')}`",
        f"- Output exports: {len(report.get('exports', []))}",
        f"- Docker stats samples: {len(report.get('resources', {}).get('docker_stats_samples', []))}",
        f"- Docker per-container observed peaks: `{json.dumps(report.get('resources', {}).get('docker_summary', {}), ensure_ascii=False)}`",
        "- Docker samples report per-container CPU and memory usage when the Docker CLI is available. They are snapshots, not exact cumulative CPU time.",
        "- FFmpeg encode time is included in the worker `Rendering video` stage. The current job API does not expose a separate encode timer, so this report does not claim to separate scene generation, frame piping, encoding, and muxing.",
        "- Upload completion includes server-side chunk assembly, validation/probe, object storage write, database writes, and queueing; the public API does not expose sub-timers for those internal operations.",
        "", f"Full event/request/resource data: `{json_path.name}`", "",
    ])
    md_path.write_text("\n".join(lines), encoding="utf-8")
    return json_path, md_path


def test_upload_edit_save_and_render_performance():
    report: dict = {
        "run_id": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "started_at_utc": _utc_now(), "api_url": API_URL,
        "input": {"file_name": VIDEO_PATH.name, "file_size_bytes": VIDEO_PATH.stat().st_size},
        "settings": {"caption_language": "auto", "translate_to": None, "upload_chunk_size_bytes": 5 * 1024 * 1024,
                     "render_quality": "standard", "aspect_ratio": "original", "change_count": 1},
        "requests": [], "upload_chunks": [], "processing": {}, "rerender": {}, "exports": [],
        "resources": {},
    }
    start = time.perf_counter()
    report["input"].update(_probe_input(VIDEO_PATH))
    stats = _DockerStats()
    stats.start()
    headers = {"Authorization": f"Bearer {TOKEN}"}
    client = httpx.Client(timeout=None, headers=headers)
    report_path: tuple[Path, Path] | None = None

    try:
        size = VIDEO_PATH.stat().st_size
        init_started = time.perf_counter()
        content_type = {
            ".mp4": "video/mp4", ".mov": "video/quicktime", ".mkv": "video/x-matroska",
            ".webm": "video/webm",
        }.get(VIDEO_PATH.suffix.lower(), mimetypes.guess_type(VIDEO_PATH.name)[0] or "video/mp4")
        response = client.post(f"{API_URL}/api/uploads/init", json={
            "file_name": VIDEO_PATH.name, "content_type": content_type, "total_size_bytes": size,
            "project_name": f"Performance run {report['run_id']}",
            "caption_language": "auto", "translate_to": None,
        })
        report["requests"].append({"name": "upload_init", "method": "POST", "path": "/api/uploads/init",
            "elapsed_seconds": round(time.perf_counter() - init_started, 4), "status_code": response.status_code,
            "request_bytes": len(json.dumps({"file_name": VIDEO_PATH.name, "total_size_bytes": size})),
            "response_bytes": len(response.content), "started_at_utc": _utc_now()})
        init = _json_response(response)
        upload_id = init["upload_id"]
        chunk_size = int(init["chunk_size_bytes"])
        report["settings"]["upload_chunk_size_bytes"] = chunk_size

        with VIDEO_PATH.open("rb") as video_file:
            chunk_index = 0
            while data := video_file.read(chunk_size):
                chunk_start = time.perf_counter()
                chunk_response = client.put(f"{API_URL}/api/uploads/{upload_id}/chunks/{chunk_index}", content=data,
                    headers={"Content-Type": "application/octet-stream"})
                elapsed = time.perf_counter() - chunk_start
                _json_response(chunk_response)
                report["upload_chunks"].append({"chunk_index": chunk_index, "bytes": len(data),
                    "elapsed_seconds": round(elapsed, 4), "throughput_mbps": round(len(data) * 8 / max(elapsed, 1e-9) / 1_000_000, 3)})
                chunk_index += 1

        complete = _timed_request(report, "upload_complete_assemble_validate_store_enqueue", "POST",
            f"{API_URL}/api/uploads/{upload_id}/complete", headers=headers)
        accepted = _json_response(complete)
        project_id, job_id = accepted["project_id"], accepted["job_id"]
        report["project_id"] = project_id
        report["processing"]["job_id"] = job_id
        report["processing"]["upload_until_processing_enqueued_seconds"] = round(time.perf_counter() - init_started, 4)

        def wait_job(job: str, section: str) -> dict:
            job_started = time.perf_counter()
            observations = []
            previous_key = None
            while time.perf_counter() - job_started < TIMEOUT_SECONDS:
                poll_started = time.perf_counter()
                result = _timed_request(report, f"{section}_job_poll", "GET", f"{API_URL}/api/jobs/{job}", headers=headers)
                state = _json_response(result)
                elapsed = time.perf_counter() - job_started
                key = (state.get("status"), state.get("stage"), state.get("progress"))
                if key != previous_key:
                    observations.append({"elapsed_seconds": elapsed, "status": state.get("status"),
                                         "stage": state.get("stage"), "progress": state.get("progress"), "at_utc": _utc_now()})
                    previous_key = key
                if state["status"] in ("completed", "failed", "cancelled"):
                    report[section].update({"final_status": state["status"], "final_stage": state.get("stage"),
                        "error": state.get("error"), "elapsed_seconds": round(elapsed, 3),
                        "poll_interval_seconds": POLL_SECONDS, "observations": observations,
                        "stage_durations": _stage_durations(observations)})
                    if state["status"] != "completed":
                        raise AssertionError(f"{section} job {state['status']}: {state.get('error')}")
                    return state
                time.sleep(max(0, POLL_SECONDS - (time.perf_counter() - poll_started)))
            raise TimeoutError(f"Timed out waiting for {section} job {job}")

        wait_job(job_id, "processing")

        caption_response = _timed_request(report, "editor_load_captions", "GET",
            f"{API_URL}/api/projects/{project_id}/captions", headers=headers)
        initial_caption = _json_response(caption_response)
        report["initial_caption"] = {"style_preset": initial_caption.get("style_preset"),
            "aspect_ratio": initial_caption.get("aspect_ratio"), "language": initial_caption.get("language"),
            "segment_count": len(initial_caption.get("caption_data", {}).get("segments", [])),
            "initial_render_fingerprint": initial_caption.get("render_fingerprint")}

        preview = _timed_request(report, "editor_load_video_preview_url", "GET",
            f"{API_URL}/api/projects/{project_id}/video/preview-url", headers=headers)
        _json_response(preview)
        edited_data, change = _edit_one_caption(initial_caption)
        report["caption_change"] = change
        save = _timed_request(report, "save_single_caption_change", "PUT",
            f"{API_URL}/api/projects/{project_id}/captions", headers=headers,
            json={"caption_data": edited_data})
        _json_response(save)

        render = _timed_request(report, "request_standard_original_render", "POST",
            f"{API_URL}/api/projects/{project_id}/render", headers=headers,
            json={"quality": "standard", "aspect_ratio": "original"})
        render_job = _json_response(render)["job_id"]
        report["rerender"]["job_id"] = render_job
        wait_job(render_job, "rerender")

        exports_response = _timed_request(report, "list_project_exports", "GET",
            f"{API_URL}/api/projects/{project_id}/exports", headers=headers)
        exports = _json_response(exports_response)
        report["exports"] = exports
        if exports:
            export_id = exports[0]["id"]
            url_response = _timed_request(report, "get_final_export_download_url", "GET",
                f"{API_URL}/api/exports/{export_id}/download", headers=headers)
            download_url = _json_response(url_response)["download_url"]
            download_start = time.perf_counter()
            downloaded = 0
            with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as output:
                output_path = Path(output.name)
                with httpx.stream("GET", download_url, timeout=None, follow_redirects=True) as download:
                    download.raise_for_status()
                    for part in download.iter_bytes():
                        output.write(part)
                        downloaded += len(part)
            report["requests"].append({"name": "download_final_export", "method": "GET",
                "path": "<signed-storage-url>", "elapsed_seconds": round(time.perf_counter() - download_start, 4),
                "status_code": 200, "request_bytes": 0, "response_bytes": downloaded, "started_at_utc": _utc_now()})
            report["rerender"]["downloaded_export_bytes"] = downloaded
            try:
                report["rerender"]["output_media"] = _probe_input(output_path)
            finally:
                output_path.unlink(missing_ok=True)

        report["total_elapsed_seconds"] = round(time.perf_counter() - start, 3)
        report["resources"] = {"docker_stats_available": stats.available,
                               "docker_stats_samples": stats.stop()}
        report["resources"]["docker_summary"] = _docker_resource_summary(report["resources"]["docker_stats_samples"])
        report_path = _write_reports(report)
        print(f"Performance report (JSON): {report_path[0]}")
        print(f"Performance report (Markdown): {report_path[1]}")
        assert report["processing"]["final_status"] == "completed"
        assert report["rerender"]["final_status"] == "completed"
    finally:
        report["resources"] = {"docker_stats_available": stats.available,
                               "docker_stats_samples": stats.stop()}
        report["resources"]["docker_summary"] = _docker_resource_summary(report["resources"]["docker_stats_samples"])
        report.setdefault("total_elapsed_seconds", round(time.perf_counter() - start, 3))
        if report_path is None:
            try:
                report_path = _write_reports(report)
                print(f"Partial performance report (JSON): {report_path[0]}")
            except OSError:
                pass
        client.close()
