"""Only confirmed terminal Modal calls may fail unfinished database jobs."""
import sys
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from models.models import JobStatus


@pytest.mark.parametrize("outcome, expected", [
    ("running", JobStatus.rendering),
    ("timeout", JobStatus.failed),
    ("finished_without_status", JobStatus.failed),
    ("network_failure", JobStatus.rendering),
])
def test_recovery_uses_modal_state(monkeypatch, outcome, expected):
    class Timeout(Exception):
        pass
    class FunctionTimeout(Timeout):
        pass
    class RemoteFailure(Exception):
        pass
    api = SimpleNamespace(
        FunctionCall=MagicMock(),
        exception=SimpleNamespace(TimeoutError=Timeout, FunctionTimeoutError=FunctionTimeout,
                                  RemoteError=RemoteFailure, UserCodeException=RemoteFailure,
                                  OutputExpiredError=RemoteFailure),
    )
    monkeypatch.setitem(sys.modules, "modal", api)
    from workers import modal_recovery
    monkeypatch.setattr(modal_recovery, "modal", api)

    job = SimpleNamespace(id="job-1", status=JobStatus.rendering, celery_task_id="fc-running")
    session = MagicMock()
    session.scalars.return_value.all.return_value = [job]
    factory = MagicMock()
    factory.return_value.__enter__.return_value = session
    monkeypatch.setattr(modal_recovery, "SyncSessionLocal", factory)

    call = api.FunctionCall.from_id.return_value
    call.get.return_value = None
    if outcome != "finished_without_status":
        call.get.side_effect = {"running": Timeout(), "timeout": FunctionTimeout(),
                                "network_failure": ConnectionError()}[outcome]
    modal_recovery.recover_finished_jobs()
    assert job.status == expected
    assert session.commit.called == (expected == JobStatus.failed)
