"""Modal dispatch must preserve job state, cancellation, and local execution."""
import sys
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest

from app.config import get_settings
from models.models import JobStatus
from workers import task_queue


@pytest.fixture
def modal_api(monkeypatch):
    api = SimpleNamespace(
        Function=Mock(), FunctionCall=Mock(),
        is_local=lambda: False,
        current_function_call_id=lambda: "fc-running",
    )
    monkeypatch.setitem(sys.modules, "modal", api)
    monkeypatch.setattr(get_settings(), "job_backend", "modal")
    return api


def test_modal_dispatch_only_sends_job_arguments(modal_api):
    modal_api.Function.from_name.return_value.spawn.return_value.object_id = "fc-queued"
    task = task_queue.ModalTask(Mock(), name="workers.tasks.rerender_project_job")
    result = task.delay("job-1", "high", "9:16")
    modal_api.Function.from_name.assert_called_once_with("video-caption-app", "rerender_project_job")
    modal_api.Function.from_name.return_value.spawn.assert_called_once_with("job-1", "high", "9:16")
    assert result.id == "fc-queued"


def test_bound_pipeline_receives_the_modal_call_id(modal_api):
    received = []

    @task_queue.task(name="workers.tasks.process_video_job", bind=True)
    def pipeline(context, job_id):
        received.append((context.request.id, job_id))

    pipeline.run("job-1")
    assert received == [("fc-running", "job-1")]


async def test_submit_persists_call_id_before_job_has_started(modal_api):
    task = SimpleNamespace(delay=Mock(return_value=SimpleNamespace(id="fc-queued")))
    job = SimpleNamespace(id="job-1", celery_task_id=None, status=JobStatus.queued)
    db = SimpleNamespace(commit=AsyncMock())
    await task_queue.submit_job(task, job, db, "standard", "original")
    assert job.celery_task_id == "fc-queued"
    assert job.status == JobStatus.queued
    db.commit.assert_awaited_once()


async def test_failed_submission_does_not_leave_job_queued(modal_api):
    task = SimpleNamespace(delay=Mock(side_effect=RuntimeError("scheduler unavailable")))
    job = SimpleNamespace(id="job-1", status=JobStatus.queued)
    db = SimpleNamespace(commit=AsyncMock())
    with pytest.raises(RuntimeError):
        await task_queue.submit_job(task, job, db)
    assert job.status == JobStatus.failed
    assert "scheduler unavailable" not in job.error
    db.commit.assert_awaited_once()


def test_modal_cancellation_stops_the_remote_call(modal_api):
    task_queue.cancel_task("fc-running")
    modal_api.FunctionCall.from_id.assert_called_once_with("fc-running")
    modal_api.FunctionCall.from_id.return_value.cancel.assert_called_once_with(terminate_containers=True)


def test_api_startup_does_not_fail_separate_modal_jobs(modal_api, monkeypatch):
    from workers import tasks

    session_factory = Mock(side_effect=AssertionError("API startup must not change worker jobs"))
    monkeypatch.setattr(tasks, "SyncSessionLocal", session_factory)
    tasks.recover_orphaned_jobs()
    session_factory.assert_not_called()
