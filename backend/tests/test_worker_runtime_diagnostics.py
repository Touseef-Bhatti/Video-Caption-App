from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from workers import tasks


def test_worker_runtime_diagnostics_records_queue_database_gpu_and_region(monkeypatch):
    created = datetime(2026, 11, 15, 8, 0, tzinfo=timezone.utc)
    worker_started = created + timedelta(seconds=3.25)

    class Result:
        def scalar(self):
            return 1

    class Session:
        calls = 0

        def execute(self, statement):
            assert str(statement) == "SELECT 1"
            self.calls += 1
            return Result()

        def rollback(self):
            raise AssertionError("successful samples must not roll back")

    monkeypatch.setattr(tasks, "_worker_has_started_job", False)
    monkeypatch.setattr(tasks, "_gpu_name", lambda: "NVIDIA L4")
    monkeypatch.setenv("MODAL_REGION", "us-east")
    session = Session()
    job = SimpleNamespace(id="job-1", created_at=created)

    diagnostics = tasks._worker_runtime_diagnostics(session, job, worker_started)

    assert diagnostics["container_cold_start"] is True
    assert diagnostics["queue_wait_seconds"] == 3.25
    assert diagnostics["db_roundtrip_ms"] is not None
    assert session.calls == 5
    assert diagnostics["gpu_name"] == "NVIDIA L4"
    assert diagnostics["region"] == "us-east"

    warm_diagnostics = tasks._worker_runtime_diagnostics(session, job, worker_started)
    assert warm_diagnostics["container_cold_start"] is False
