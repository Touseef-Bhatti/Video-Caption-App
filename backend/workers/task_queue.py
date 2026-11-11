"""Dispatch existing pipeline functions through Modal or local Celery."""
from functools import update_wrapper
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

        function = modal.Function.from_name(get_settings().modal_app_name, self.name)
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


def task(*, name, bind=False):
    if get_settings().job_backend == "modal":
        return lambda function: ModalTask(function, name=name, bind=bind)
    from workers.celery_app import celery_app

    return celery_app.task(name=name, bind=bind)


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
