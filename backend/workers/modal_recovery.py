"""Reconcile interrupted Modal jobs without guessing from API restarts."""
import logging

import modal
from sqlalchemy import select

from models.models import JobStatus, ProcessingJob
from workers.db_sync import SyncSessionLocal

logger = logging.getLogger(__name__)
FINISHED = {JobStatus.completed, JobStatus.failed, JobStatus.cancelled}


def recover_finished_jobs():
    with SyncSessionLocal() as session:
        jobs = session.scalars(select(ProcessingJob).where(
            ProcessingJob.status.not_in(FINISHED),
            ProcessingJob.celery_task_id.startswith("fc-"),
        )).all()
        for job in jobs:
            try:
                modal.FunctionCall.from_id(job.celery_task_id).get(timeout=0)
            except modal.exception.FunctionTimeoutError:
                pass
            except modal.exception.TimeoutError:
                # Modal explicitly confirms this call is still pending/running.
                continue
            except (modal.exception.RemoteError,
                    modal.exception.UserCodeException, modal.exception.OutputExpiredError):
                pass  # A terminal call failure left no final database status.
            except Exception:
                # Network/auth/lookup failures do not establish that a job died.
                logger.exception("Could not check Modal call for job %s", job.id)
                continue
            session.refresh(job)
            if job.status not in FINISHED:
                job.status = JobStatus.failed
                job.stage = "Failed"
                job.error = "Processing was interrupted. Please try again."
                session.commit()
