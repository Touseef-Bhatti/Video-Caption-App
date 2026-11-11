"""Single-process Celery worker with a threaded scheduler for the free service."""

import os

from celery.beat import EmbeddedService
from celery.signals import worker_ready

from workers.celery_app import celery_app


def main():
    os.environ.setdefault("CAPTION_RENDERER_LOW_MEMORY", "1")
    scheduler = EmbeddedService(celery_app, thread=True)

    def start_scheduler(**_):
        scheduler.start()

    worker_ready.connect(start_scheduler, weak=False)
    try:
        celery_app.worker_main([
            "worker", "--loglevel=info", "--pool=solo", "--concurrency=1",
            "--without-gossip", "--without-mingle",
        ])
    finally:
        worker_ready.disconnect(start_scheduler)
        if scheduler.is_alive():
            scheduler.stop()


if __name__ == "__main__":
    main()
