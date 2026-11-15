import importlib.util
import json
from pathlib import Path
import sys

from services.ffmpeg_service import VideoProbe
from services.render_scene import RENDERER_VERSION


def test_benchmark_writes_page_shaped_report_for_both_strategies(tmp_path, monkeypatch):
    source = tmp_path / "source.mp4"
    source.write_bytes(b"source")
    snapshot = tmp_path / "snapshot.json"
    snapshot.write_text(json.dumps({"renderer_version": RENDERER_VERSION,
                                    "caption_data": {"language": "English", "segments": []},
                                    "style_preset": "simple_white", "aspect_ratio": "original"}),
                        encoding="utf-8")
    script = Path(__file__).resolve().parents[2] / "scripts/bench_render_strategy.py"
    spec = importlib.util.spec_from_file_location("bench_render_strategy", script)
    benchmark = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(benchmark)
    monkeypatch.setattr(benchmark, "probe_video", lambda _: VideoProbe(1, 160, 90, False, "mp4"))

    def fake_render(_source, _snapshot, output, *, probe, metrics):
        output.write_bytes(b"output")
        metrics.update({"capture": {"strategy": benchmark.os.environ["CAPTION_RENDER_STRATEGY"]}})

    monkeypatch.setattr(benchmark, "render_scene", fake_render)
    for key in ("JWT_SECRET", "DATABASE_URL", "GEMINI_API_KEY", "CAPTION_RENDER_STRATEGY"):
        monkeypatch.setenv(key, "test")
    output_dir = tmp_path / "reports"
    monkeypatch.setattr(sys, "argv", ["bench_render_strategy.py", str(source), str(snapshot),
                                      "--repeats", "1", "--output-dir", str(output_dir)])
    benchmark.main()
    reports = [json.loads(path.read_text(encoding="utf-8"))
               for path in output_dir.glob("*.json")]
    assert len(reports) == 2
    assert {report["settings"]["caption_render_strategy"] for report in reports} == {
        "legacy", "adaptive"}
    for report in reports:
        assert report["rerender"]["final_status"] == "completed"
        assert report["rerender"]["server_diagnostics"]["render"]["capture"]["strategy"] == (
            report["settings"]["caption_render_strategy"])
        assert report["exports"][0]["output_bytes"] == 6
        assert {"requests", "upload_chunks", "events", "processing", "rerender",
                "resources", "exports", "total_elapsed_seconds"}.issubset(report)
