"""Exercise service supervision with real child processes and no external services."""

import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

import start_service


class ServiceSupervisionTests(unittest.TestCase):
    def run_service(self, api_script, worker_script, stop=None):
        children = []
        real_popen = subprocess.Popen

        def launch(command, **kwargs):
            script = api_script if command[0] == "uvicorn" else worker_script
            process = real_popen([sys.executable, "-c", script], **kwargs)
            children.append(process)
            return process

        with patch.object(start_service.subprocess, "run"), \
                patch.object(start_service.subprocess, "Popen", side_effect=launch), \
                patch.object(start_service, "urlopen") as health:
            health.return_value.__enter__.return_value.status = 200
            result = start_service.main(stop)
        self.assertTrue(all(child.poll() is not None for child in children))
        return result, children

    def test_worker_failure_stops_api_and_returns_failure(self):
        result, children = self.run_service("import time; time.sleep(60)", "raise SystemExit(7)")
        self.assertEqual(result, 7)
        self.assertEqual(len(children), 2)

    def test_api_failure_stops_worker_and_returns_failure(self):
        result, _ = self.run_service("raise SystemExit(3)", "import time; time.sleep(60)")
        self.assertIn(result, (1, 3))

    def test_requested_shutdown_stops_both_children_cleanly(self):
        stop = threading.Event()
        timer = threading.Timer(1, stop.set)
        timer.start()
        try:
            result, children = self.run_service(
                "import time; time.sleep(60)", "import time; time.sleep(60)", stop,
            )
            self.assertEqual(result, 0)
            self.assertEqual(len(children), 2)
        finally:
            timer.cancel()


if __name__ == "__main__":
    unittest.main()
