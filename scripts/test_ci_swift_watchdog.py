# tako — Swift CI progress supervision tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


WATCHDOG = Path(__file__).with_name("ci-swift-watchdog.py")


class SwiftWatchdogTests(unittest.TestCase):
    def supervise(self, code, idle=0.3):
        with tempfile.TemporaryDirectory(prefix="tako-watchdog-test-") as directory:
            return subprocess.run(
                [sys.executable, str(WATCHDOG), "--idle-timeout", str(idle),
                 "--diagnostics-dir", directory, "--", sys.executable, "-c", code],
                capture_output=True, text=True, timeout=8)

    def test_success_keeps_output_and_exit_status(self):
        result = self.supervise("print('◇ Test run started.'); print('1 test passed')")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 test passed", result.stdout)

    def test_failure_exit_is_not_reported_as_success(self):
        result = self.supervise("import sys; print('failure'); sys.exit(7)")
        self.assertEqual(result.returncode, 7)

    def test_child_signal_keeps_the_shell_exit_status(self):
        result = self.supervise("import os,signal; os.kill(os.getpid(), signal.SIGTERM)")
        self.assertEqual(result.returncode, 143)

    def test_compile_time_does_not_use_the_runtime_idle_budget(self):
        result = self.supervise("import time; time.sleep(0.5); print('compilation finished')", idle=0.1)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_progress_extends_the_idle_deadline(self):
        result = self.supervise(
            "import time; print('◇ Test run started.', flush=True); "
            "[(print('progress', flush=True), time.sleep(0.1)) for _ in range(6)]")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_stalled_runtime_fails_and_reaps_its_child(self):
        result = self.supervise(
            "import os,time; print('child-pid='+str(os.getpid()), flush=True); "
            "print(\"Test Suite 'All tests' started\", flush=True); time.sleep(20)")
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        self.assertIn("collecting native stacks", result.stdout)
        pid = int(next(line.split("=", 1)[1] for line in result.stdout.splitlines() if line.startswith("child-pid=")))
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_xcodebuild_stall_collects_the_owned_driver_stack(self):
        diagnose = runpy.run_path(str(WATCHDOG))["diagnose"]
        rows = [
            ["123", "1", "123", "S", "0", "100", "/usr/bin/xcodebuild"],
            ["124", "123", "123", "S", "0", "100", "/bin/sh"],
        ]
        with tempfile.TemporaryDirectory(prefix="tako-watchdog-stack-") as directory:
            with mock.patch.dict(diagnose.__globals__, descendants=lambda _: rows), \
                    mock.patch.object(shutil, "which", side_effect=lambda tool:
                                      "/usr/bin/sample" if tool == "sample" else None), \
                    mock.patch.object(subprocess, "run", return_value=SimpleNamespace(
                        stdout="owned xcodebuild stack\n", stderr="")) as sample:
                diagnose(SimpleNamespace(pid=123), Path(directory))
            sample.assert_called_once_with(
                ["/usr/bin/sample", "123", "3", "1"],
                capture_output=True, text=True, timeout=10)
            self.assertEqual((Path(directory) / "swift-test-123.txt").read_text(),
                             "owned xcodebuild stack\n")


if __name__ == "__main__":
    unittest.main()
