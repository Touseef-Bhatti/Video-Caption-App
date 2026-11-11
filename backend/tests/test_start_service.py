"""Exercise shared-process startup and failure handling with real API threads."""

import os
import signal
import subprocess
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

import start_service


class FakeServer:
    def __init__(self, _config):
        self.started = False
        self.should_exit = False
        self.force_exit = False
        self.crash = threading.Event()
        self.thread = None

    def run(self):
        self.thread = threading.current_thread()
        self.started = True
        while not self.should_exit and not self.crash.wait(0.01):
            pass


class ServiceSupervisionTests(unittest.TestCase):
    def run_service(self, worker_action, server_type=FakeServer):
        server = server_type(None)
        worker = Mock(side_effect=lambda: worker_action(server))
        uvicorn = types.SimpleNamespace(Config=Mock(), Server=Mock(return_value=server))
        with patch.object(start_service.subprocess, "run"), patch.dict(
            "sys.modules", {"uvicorn": uvicorn, "start_worker": types.SimpleNamespace(main=worker)},
        ):
            result = start_service.main()
        self.assertFalse(server.thread.is_alive())
        return result, server, worker

    def test_worker_failure_stops_api_and_returns_failure(self):
        def fail(server):
            self.assertTrue(server.started)
            raise RuntimeError("worker failed")
        result, _, _ = self.run_service(fail)
        self.assertEqual(result, 1)

    def test_api_failure_requests_worker_shutdown(self):
        shutdown = threading.Event()
        def worker(server):
            server.crash.set()
            self.assertTrue(shutdown.wait(3))
        with patch.object(start_service.os, "kill", side_effect=lambda *_: shutdown.set()) as kill:
            result, _, _ = self.run_service(worker)
        self.assertEqual(result, 1)
        kill.assert_called_once_with(os.getpid(), signal.SIGTERM)

    def test_normal_worker_shutdown_stops_api(self):
        result, server, _ = self.run_service(lambda _: None)
        self.assertEqual(result, 0)
        self.assertTrue(server.should_exit)

    def test_api_must_be_ready_before_worker_starts(self):
        class FailedServer(FakeServer):
            def run(self):
                self.thread = threading.current_thread()
        result, _, worker = self.run_service(lambda _: None, FailedServer)
        self.assertEqual(result, 1)
        worker.assert_not_called()

    def test_failed_migration_prevents_startup(self):
        with patch.object(start_service.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "alembic")):
            self.assertEqual(start_service.main(), 1)


if __name__ == "__main__":
    unittest.main()
