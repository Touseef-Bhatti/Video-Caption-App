"""Share one Python process between the API and caption worker on Render Free."""

import os
import signal
import subprocess
import threading
import time


def main():
    server = None
    api_thread = None
    stopping = threading.Event()
    api_failed = threading.Event()
    try:
        subprocess.run(["alembic", "upgrade", "head"], check=True)
        import uvicorn
        from start_worker import main as run_worker

        server = uvicorn.Server(uvicorn.Config(
            "app.main:app", host="0.0.0.0",
            port=int(os.environ.get("PORT", "8000")), loop="asyncio",
        ))

        def run_api():
            try:
                server.run()
            except Exception as exc:
                print(f"API failed: {exc}", flush=True)
                api_failed.set()

        api_thread = threading.Thread(target=run_api, name="caption-api", daemon=True)
        api_thread.start()
        deadline = time.monotonic() + 90
        while not server.started:
            if not api_thread.is_alive():
                raise RuntimeError("API exited before becoming ready")
            if time.monotonic() >= deadline:
                raise RuntimeError("API did not become ready within 90 seconds")
            time.sleep(0.1)

        def watch_api():
            while not stopping.wait(0.5):
                if not api_thread.is_alive():
                    api_failed.set()
                    # Celery owns the main thread and handles graceful shutdown.
                    os.kill(os.getpid(), signal.SIGTERM)
                    return

        threading.Thread(target=watch_api, name="caption-api-monitor", daemon=True).start()
        print("API ready; starting caption worker in the shared process", flush=True)
        run_worker()
        return 1 if api_failed.is_set() else 0
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 1
    except Exception as exc:
        print(f"Service failed: {exc}", flush=True)
        return 1
    finally:
        stopping.set()
        if server is not None:
            server.should_exit = True
        if api_thread is not None:
            api_thread.join(timeout=20)
            if api_thread.is_alive():
                server.force_exit = True
                api_thread.join(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
