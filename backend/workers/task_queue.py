"""Dispatch existing pipeline functions through Modal or local Celery."""
from functools import update_wrapper
import os
from types import SimpleNamespace

from app.config import get_settings


class ModalTask:
    def __init__(self, function, *, name, bind=False):
        self.function = function
        self.name = name.rsplit(".", 1)[-1]
        self.bind = bind
        update_wrapper(self, function)

    def delay(self, *args, **kwargs):
        import modal

        settings = get_settings()
        function = modal.Function.from_name(
            settings.modal_app_name, self.name + settings.modal_function_suffix
        )
        if self.name == "rerender_project_job" and len(args) >= 5:
            resolution, fps = int(args[3]), int(args[4])
            gpu_policy = os.environ.get("MODAL_RENDER_GPU", "auto").lower()
            if gpu_policy == "none":
                gpu = None
            elif gpu_policy != "auto":
                gpu = os.environ["MODAL_RENDER_GPU"]
            elif resolution <= 1024 and fps <= 30:
                gpu = ["T4", "L4", "A10"]
            elif resolution <= 2048 and fps <= 60:
                gpu = ["L4", "A10", "T4"]
            else:
                # High profiles can still run on T4 when preferred GPUs are
                # saturated. It may take longer, but gives Modal another
                # compatible GPU type to schedule instead of waiting only on
                # A10/L4 capacity.
                gpu = ["A10", "L4", "T4"]
            function = function.with_options(gpu=gpu, max_containers=1)
        call = function.spawn(*args, **kwargs)
        return SimpleNamespace(id=call.object_id)

    def run(self, *args, **kwargs):
        if self.bind:
            import modal

            call_id = None if modal.is_local() else modal.current_function_call_id()
            context = SimpleNamespace(request=SimpleNamespace(id=call_id))
            return self.function(context, *args, **kwargs)
        return self.function(*args, **kwargs)

    __call__ = run


def task(*, name, bind=False, queue=None):
    if get_settings().job_backend == "modal":
        return lambda function: ModalTask(function, name=name, bind=bind)
    from workers.celery_app import celery_app

    return celery_app.task(name=name, bind=bind, queue=queue)


async def submit_job(task, job, db, *args):
    """Persist the remote call ID for cancellation, including queued jobs."""
    import asyncio
    import logging
    from models.models import JobStatus

    try:
        result = await asyncio.to_thread(task.delay, job.id, *args)
    except Exception:
        logging.getLogger(__name__).exception("Could not submit job %s", job.id)
        job.status = JobStatus.failed
        job.stage = "Failed"
        job.error = "We couldn't start this job right now. Please try again."
        await db.commit()
        raise
    if result is not None:
        # Keep the existing column to avoid a destructive database migration.
        job.celery_task_id = result.id
        await db.commit()


def cancel_task(task_id):
    if get_settings().job_backend == "modal":
        import modal

        modal.FunctionCall.from_id(task_id).cancel(terminate_containers=True)
    else:
        from workers.celery_app import celery_app

        celery_app.control.revoke(task_id, terminate=True)
