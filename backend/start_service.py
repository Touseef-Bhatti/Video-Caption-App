"""Run the API and one caption worker together on a single Render service."""

import os
import signal
import subprocess
import threading
import time
from urllib.error import URLError
from urllib.request import urlopen


def _wait_for_api(process, stop, port, timeout=90):
    deadline = time.monotonic() + timeout
    while not stop.is_set() and time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("API exited before becoming ready")
        try:
            with urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1) as response:
                if response.status == 200:
                    return True
        except (OSError, URLError):
            pass
        stop.wait(0.5)
    if stop.is_set():
        return False
    raise RuntimeError("API did not become ready within 90 seconds")


def _stop_processes(processes):
    for process in processes:
        if process.poll() is None:
            process.terminate()
    deadline = time.monotonic() + 20
    for process in processes:
        try:
            process.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            pass
        # Also clean up FFmpeg/Chromium descendants left by an interrupted job.
        if os.name == "posix":
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        elif process.poll() is None:
            process.kill()
        process.wait()


def main(stop=None):
    stop = stop if stop is not None else threading.Event()
    previous_handlers = {}
    for sig in (signal.SIGTERM, signal.SIGINT):
        previous_handlers[sig] = signal.signal(sig, lambda *_: stop.set())
    processes = []
    try:
        subprocess.run(["alembic", "upgrade", "head"], check=True)
        if stop.is_set():
            return 0
        port = os.environ.get("PORT", "8000")
        api = subprocess.Popen([
            "gunicorn", "app.main:app", "-k", "uvicorn.workers.UvicornWorker",
            "--bind", f"0.0.0.0:{port}", "--workers", "1", "--timeout", "120",
        ], start_new_session=True)
        processes.append(api)
        # Startup recovery must finish before the worker starts consuming jobs.
        if not _wait_for_api(api, stop, port):
            return 0
        worker = subprocess.Popen([
            "celery", "-A", "workers.celery_app", "worker", "--beat",
            "--loglevel=info", "--pool=solo", "--concurrency=1",
            "--without-gossip", "--without-mingle",
        ], start_new_session=True)
        processes.append(worker)
        print("API and single-job caption worker started", flush=True)
        while not stop.wait(0.5):
            for name, process in zip(("API", "Caption worker"), processes):
                code = process.poll()
                if code is not None:
                    print(f"{name} exited with code {code}; stopping service", flush=True)
                    return code if code > 0 else 1
        return 0
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"Service startup failed: {exc}", flush=True)
        return 1
    finally:
        _stop_processes(processes)
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    raise SystemExit(main())
