#!/usr/bin/env python3
# tako — Concise CI console over a complete raw log: tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""scripts/ci_log.py with stand-in commands only (python3 -c / sh -c): no
build, no test campaign, nothing outside a temporary directory."""

import io
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ci_log  # noqa: E402

FLOOD = r"""
import sys
w = sys.stdout.write
w("== swift-tests\n")
w("/usr/bin/swiftc -module-name TakoApp " + " ".join(f"/src/F{i}.swift" for i in range(400)) + "\n")
for i in range(3000):
    w(f"/src/File{i % 7}.swift:{i}:1: warning: 'foo' is deprecated\n")
    w(f"    let error = foo()  // context line {i}\n" if i % 2 else f"    ^~~~ {i}\n")
w("Test Suite 'All tests' started at 2026-11-16\n")
for i in range(2000):
    w(f"Test Case '-[T.C test{i}]' started.\n")
    w(f"    t =     {i}.00s Find the \"terminal\" TextView\n")
    w(f"[xcui progress {i}] defaults remove begin\n")
    w(f"Test Case '-[T.C test{i}]' passed (0.01 seconds).\n")
    w(f"Test Suite 'C{i}' passed at 2026-11-16.\n")
    w(f"\t Executed 1 test, with 0 failures (0 unexpected) in 0.01 (0.01) seconds\n")
    w(f"✔ Test case{i}() passed after 0.001 seconds.\n")
w("Test Suite 'All tests' passed at 2026-11-16 12:00:00.000.\n")
w("\t Executed 2000 tests, with 0 failures (0 unexpected) in 20.0 (20.1) seconds\n")
w("✔ Test run with 2000 tests in 50 suites passed after 20.0 seconds.\n")
w("** TEST SUCCEEDED **\n")
"""


class CiLogTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = tmp.name

    def run_logged(self, code, **kwargs):
        console = io.StringIO()
        raw = os.path.join(self.dir, "logs", "stage.log")
        result = ci_log.run_logged([sys.executable, "-c", code], raw, label="stage", out=console, **kwargs)
        return result, console.getvalue(), raw

    def test_the_raw_log_keeps_every_byte(self):
        code = ("import sys; b = sys.stdout.buffer; b.write(b'\\xff\\xfe not utf-8\\r\\n'); "
                "b.write(b'x' * 5000 + b'\\n'); b.write(b'warning: one\\n' * 3); b.write(b'no trailing newline')")
        expected = (b"\xff\xfe not utf-8\r\n" + b"x" * 5000 + b"\n" + b"warning: one\n" * 3 + b"no trailing newline")
        (_, status, text), console, raw = self.run_logged(code)
        self.assertEqual(status, 0)
        with open(raw, "rb") as f:
            self.assertEqual(f.read(), expected)
        self.assertEqual(text, expected.decode("utf-8", "replace"), "the complete output is returned")
        self.assertNotIn("x" * 400, console, "a pathological line is clipped on the console")

    def test_warnings_compiler_lists_and_per_case_lines_do_not_flood_the_console(self):
        (_, status, text), console, raw = self.run_logged(FLOOD)
        lines = console.splitlines()
        self.assertEqual(status, 0)
        self.assertLess(len(lines), 15, console)
        self.assertIn("== swift-tests", console)
        self.assertIn("Test Suite 'All tests' passed", console)
        self.assertIn("Executed 2000 tests, with 0 failures", console)
        self.assertNotIn("Executed 1 test", console, "nested suites' totals stay in the raw log")
        self.assertIn("Test run with 2000 tests in 50 suites passed", console)
        self.assertIn("** TEST SUCCEEDED **", console)
        self.assertIn("3000 warnings", lines[-1])
        body = "\n".join(lines[1:])  # the start line echoes the stand-in's own source
        self.assertTrue(lines[0].startswith("[stage] start: ") and len(lines[0]) < ci_log.MAX_LINE + 60, lines[0])
        for noise in ("swiftc -module-name", "warning:", "started.", "t =", "xcui progress", "' passed (", "✔ Test case"):
            self.assertNotIn(noise, body)
        # The completion parsers read the raw log, which has everything.
        with open(raw) as f:
            raw_text = f.read()
        self.assertEqual(raw_text, text)
        self.assertEqual(raw_text.count("Test Case '-["), 4000)
        self.assertEqual(raw_text.count("warning: 'foo' is deprecated"), 3000)

    def test_failures_are_shown_bounded_and_with_a_tail(self):
        code = ("import sys\n"
                "for i in range(500): print(f'/src/A.swift:{i}:1: error: cannot find thing{i}')\n"
                "print(\"Test Case '-[T.C testX]' failed (1.0 seconds).\")\n"
                "sys.exit(3)\n")
        (_, status, _), console, _ = self.run_logged(code)
        self.assertEqual(status, 3)
        self.assertIn("error: cannot find thing0", console)
        shown = [l for l in console.splitlines()
                 if "error: cannot find" in l and not l.startswith(("  ", "[stage] start:"))]
        self.assertEqual(len(shown), ci_log.MAX_ERRORS)
        self.assertIn(f"last {ci_log.FAILURE_TAIL} lines", console)
        self.assertIn("Test Case '-[T.C testX]' failed", console)
        self.assertIn("FAILED (exit 3)", console.splitlines()[-1])
        self.assertIn("501 failure lines (461 repeated or over the limit", console.splitlines()[-1])

    def test_noise_that_only_mentions_errors_and_repeated_issues_stay_off_the_console(self):
        code = (
            "for i in range(300):\n"
            "    print(f'2026-11-16 19:48:{i:02d} xcodebuild[1:2] [MT] IDELaunchParametersSnapshot: The operation "
            "couldn\\u2019t be completed. (DebuggerLLDB.DebuggerVersionStore.StoreError error 0.)')\n"
            "    print(f'    t =    {i}.0s Waiting 5.0s for \"DesktopSetting-sidebar-count-error\" Any to exist')\n"
            "    print(f'331 |         #expect(f(Weights.near(MotionSpec.error)) > 0.95, \"no baseline\")')\n"
            "    print(f'\\u2718 Test liveTile() recorded an issue at Hosted.swift:78:17: Expectation failed: close(({i}.0, 8))')\n"
            "    print(f'/w/T.swift:34: error: -[T.C testBlink] : XCTAssertEqualWithAccuracy failed: (\"{i}\")')\n"
            "print(\"Test Case '-[T.C testBlink]' failed (2.5 seconds).\")\n"
            "print('\\u2718 Test liveTile() failed after 1.0 seconds with 300 issues.')\n"
            "print('\\u2718 Test run with 9 tests in 2 suites failed after 3.0 seconds with 300 issues.')\n")
        (_, status, _), console, _ = self.run_logged(code)
        self.assertEqual(status, 0)
        body = console.splitlines()[1:]
        self.assertEqual(body[:-1], [
            "✘ Test liveTile() recorded an issue at Hosted.swift:78:17: Expectation failed: close((0.0, 8))",
            "/w/T.swift:34: error: -[T.C testBlink] : XCTAssertEqualWithAccuracy failed: (\"0\")",
            "Test Case '-[T.C testBlink]' failed (2.5 seconds).",
            "✘ Test liveTile() failed after 1.0 seconds with 300 issues.",
            "✘ Test run with 9 tests in 2 suites failed after 3.0 seconds with 300 issues.",
        ])
        self.assertIn("600 other error/fail mentions", body[-1])  # the snapshot and t = lines
        self.assertLess(len(console.splitlines()), ci_log.MAX_ERRORS + ci_log.FAILURE_TAIL + 10)

    def test_the_command_status_is_kept_through_the_command_line(self):
        raw = os.path.join(self.dir, "cli.log")
        r = subprocess.run([sys.executable, os.path.join(HERE, "ci_log.py"), "--log", raw, "--label", "x", "--",
                            "sh", "-c", "echo out; exit 7"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 7)
        r = subprocess.run([sys.executable, os.path.join(HERE, "ci_log.py"), "--log", raw, "--",
                            "sh", "-c", "kill -TERM $$"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 128 + 15)
        r = subprocess.run([sys.executable, os.path.join(HERE, "ci_log.py"), "--log", raw, "--", "true"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)

    def test_a_wrapper_that_cannot_log_never_reports_a_pass(self):
        blocked = os.path.join(self.dir, "file")
        open(blocked, "w").close()
        r = subprocess.run([sys.executable, os.path.join(HERE, "ci_log.py"), "--log",
                            os.path.join(blocked, "under-a-file.log"), "--", "true"], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("FAIL: ci_log.py could not run or log", r.stderr)

    def test_a_silent_command_still_shows_it_is_alive(self):
        code = "import time; time.sleep(1.3); print('done')"
        (_, status, _), console, _ = self.run_logged(code, heartbeat=0.4)
        self.assertEqual(status, 0)
        beats = [l for l in console.splitlines() if "still running" in l]
        self.assertGreaterEqual(len(beats), 2, console)
        self.assertLessEqual(len(beats), 4, console)

    def test_verbose_shows_everything_live(self):
        (_, status, _), console, _ = self.run_logged(FLOOD, verbose=True)
        self.assertEqual(status, 0)
        self.assertIn("warning: 'foo' is deprecated", console)
        self.assertIn("xcui progress", console)
        self.assertGreater(len(console.splitlines()), 20000)

    def test_check_run_returns_the_complete_output_and_keeps_a_per_check_file(self):
        env = dict(os.environ)
        r = subprocess.run([sys.executable, "-c", (
            "import io, os, sys, contextlib\n"
            f"sys.argv = ['check_run.py']\n"
            f"sys.path.insert(0, {HERE!r})\n"
            "import runpy\n"
            f"ns = runpy.run_path({os.path.join(HERE, 'check_run.py')!r}, run_name='check_run_test')\n"
            f"os.chdir({self.dir!r})\n"
            "secs, code, out = ns['run']([sys.executable, '-c', \"print('test result: ok. 3 passed; 0 failed');print('warning: x')\"])\n"
            "assert code == 0, code\n"
            "assert 'warning: x' in out and 'test result: ok. 3 passed' in out, out\n"
            "runs = os.listdir('target/check-logs')\n"
            "assert len(runs) == 1, runs\n"
            "logs = os.listdir(os.path.join('target/check-logs', runs[0]))\n"
            "assert len(logs) == 1, logs\n"
            "print('CHECKED', logs[0])\n")], capture_output=True, text=True, env=env, cwd=self.dir)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("CHECKED", r.stdout)
        self.assertIn("test result: ok. 3 passed", r.stdout)
        self.assertNotIn("\nwarning: x\n", r.stdout, "the warning stays in the per-check file")

    def test_check_run_keeps_both_runs_when_the_pid_and_command_repeat(self):
        script = (
            "import os, sys, time, runpy\n"
            f"sys.path.insert(0, {HERE!r})\n"
            "os.getpid = lambda: 4242\n"
            "time.strftime = lambda *a: '20261117-000000'\n"
            f"ns = runpy.run_path({os.path.join(HERE, 'check_run.py')!r}, run_name='check_run_test')\n"
            f"os.chdir({self.dir!r})\n"
            "secs, code, out = ns['run']([sys.executable, '-c', 'import sys; sys.stdout.buffer.write(sys.argv[1].encode())', sys.argv[1]])\n"
            "assert code == 0, code\n")
        for payload in ("first run bytes\n", "second run bytes\n"):
            r = subprocess.run([sys.executable, "-c", script, payload], capture_output=True, text=True, cwd=self.dir)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        root = os.path.join(self.dir, "target", "check-logs")
        runs = sorted(os.listdir(root))
        self.assertEqual(len(runs), 2, runs)
        self.assertTrue(all(name.startswith("20261117-000000-4242-") for name in runs), runs)
        kept = set()
        for run in runs:
            (log,) = os.listdir(os.path.join(root, run))
            with open(os.path.join(root, run, log), "rb") as f:
                kept.add(f.read())
        self.assertEqual(kept, {b"first run bytes\n", b"second run bytes\n"})

    def test_an_exclusive_log_never_replaces_an_existing_file(self):
        path = os.path.join(self.dir, "kept.log")
        with open(path, "wb") as f:
            f.write(b"earlier evidence")
        with self.assertRaises(FileExistsError):
            ci_log.run_logged(["true"], path, out=io.StringIO(), exclusive=True)
        with open(path, "rb") as f:
            self.assertEqual(f.read(), b"earlier evidence")


# Like scripts/ci-swift-watchdog.py: starts the real work in its own session
# and stops that group from its SIGTERM handler. A SIGKILL would skip it.
# Every process names the test's own directory on its command line, so
# cleanup can tell it from an unrelated process that reused its PID.
WORKER = "import sys, time; time.sleep(300)"
WATCHDOG_LIKE = r"""
import os, signal, subprocess, sys, time
state = sys.argv[1]
open(os.path.join(state, "watchdog.pid"), "w").write(str(os.getpid()))
worker = subprocess.Popen([sys.executable, "-c", %r, state], start_new_session=True)
open(os.path.join(state, "worker.pid"), "w").write(str(worker.pid))
def stop(number, _frame):""" % WORKER + r"""
    os.killpg(worker.pid, signal.SIGTERM)
    worker.wait()
    print("watchdog cleanup: worker group stopped", flush=True)
    open(os.path.join(state, "cleaned"), "w").write("yes")
    sys.exit(128 + number)
signal.signal(signal.SIGTERM, signal.SIG_IGN if len(sys.argv) > 2 else stop)
print("== stage", flush=True)
while True:
    time.sleep(0.1)
"""

# Closes both output streams, ignores SIGTERM and stays alive.
SILENT_STAYER = r"""
import os, signal, sys, time
state = sys.argv[1]
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(os.path.join(state, "watchdog.pid"), "w").write(str(os.getpid()))
os.close(1)
os.close(2)
time.sleep(300)
"""


class CiLogStopTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = tmp.name
        self.script = os.path.join(self.dir, "watchdog_like.py")
        with open(self.script, "w") as f:
            f.write(WATCHDOG_LIKE)
        # Runs before the directory is removed (cleanups are LIFO), whether
        # the test passed, failed or met a mutant.
        self.addCleanup(self.end_owned_processes)

    def owned_pid(self, name):
        """The PID in `name` if that process is still this test's own."""
        try:
            with open(os.path.join(self.dir, name)) as f:
                pid = int(f.read())
        except (OSError, ValueError):
            return None
        r = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
        return pid if r.returncode == 0 and self.dir in r.stdout else None

    def end_owned_processes(self):
        for name in ("watchdog.pid", "worker.pid"):
            pid = self.owned_pid(name)
            if pid is not None:
                _kill_quietly(pid)

    def wait_for(self, name, seconds=10):
        path = os.path.join(self.dir, name)
        deadline = time.monotonic() + seconds
        while not os.path.exists(path) and time.monotonic() < deadline:
            time.sleep(0.05)
        return os.path.exists(path)

    def worker_alive(self, name="worker.pid"):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.owned_pid(name) is None:
                return False
            time.sleep(0.05)
        return True

    def test_a_failing_console_lets_the_command_clean_up_and_never_passes(self):
        class BrokenConsole(io.StringIO):
            def write(self, text):
                if "== stage" in text:
                    raise BrokenPipeError("console went away")
                return super().write(text)

        with self.assertRaises(BrokenPipeError):
            ci_log.run_logged([sys.executable, self.script, self.dir], os.path.join(self.dir, "raw.log"),
                              out=BrokenConsole())
        self.assertTrue(self.wait_for("cleaned", 1), "the command's SIGTERM cleanup ran")
        self.assertFalse(self.worker_alive(), "the separate-session worker was stopped")

    def test_cancelling_the_wrapper_reaches_the_command_and_keeps_its_cleanup_output(self):
        raw = os.path.join(self.dir, "raw.log")
        wrapper = subprocess.Popen([sys.executable, os.path.join(HERE, "ci_log.py"), "--log", raw, "--",
                                    sys.executable, self.script, self.dir],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertTrue(self.wait_for("worker.pid"))
        time.sleep(0.3)  # the handler is installed after the pid file
        wrapper.send_signal(signal.SIGTERM)
        out, _ = wrapper.communicate(timeout=30)
        self.assertEqual(wrapper.returncode, 128 + signal.SIGTERM, out)
        self.assertTrue(self.wait_for("cleaned", 1))
        self.assertFalse(self.worker_alive())
        with open(raw, "rb") as f:
            self.assertIn(b"watchdog cleanup: worker group stopped", f.read())
        self.assertIn(b"interrupted by signal 15", out)
        self.assertNotIn(b"] ok in", out)

    def test_a_command_that_ignores_sigterm_is_killed_after_the_grace(self):
        proc = subprocess.Popen([sys.executable, self.script, self.dir, "ignore-term"],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertTrue(self.wait_for("worker.pid"))
        time.sleep(0.3)
        started = time.monotonic()
        ci_log.stop_child(proc, grace=0.5)
        self.assertEqual(proc.returncode, -signal.SIGKILL)
        self.assertLess(time.monotonic() - started, 5)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "cleaned")))
        proc.stdout.close()
        # Its worker is still running (no cleanup ran); tearDown ends it.
        self.assertIsNotNone(self.owned_pid("worker.pid"))

    def test_a_signalled_command_that_closed_its_output_is_still_stopped_after_the_grace(self):
        script = os.path.join(self.dir, "silent_stayer.py")
        with open(script, "w") as f:
            f.write(SILENT_STAYER)

        def cancel():
            if self.wait_for("watchdog.pid"):
                time.sleep(0.5)  # past the child's os.close: the wrapper is waiting after EOF
                os.kill(os.getpid(), signal.SIGTERM)

        threading.Thread(target=cancel, daemon=True).start()
        started = time.monotonic()
        seconds, status, _ = ci_log.run_logged([sys.executable, script, self.dir], os.path.join(self.dir, "raw.log"),
                                               out=io.StringIO(), grace=0.5)
        self.assertEqual(status, 128 + signal.SIGTERM)
        self.assertLess(time.monotonic() - started, 10)
        self.assertFalse(self.worker_alive("watchdog.pid"), "the command was killed after the grace")
        self.assertIs(signal.getsignal(signal.SIGTERM), signal.SIG_DFL, "the wrapper restored the handler")

    def test_an_ordinary_command_that_closes_its_output_early_still_finishes_normally(self):
        code = "import os, time; print('done', flush=True); os.close(1); os.close(2); time.sleep(0.6)"
        seconds, status, text = ci_log.run_logged(
            [sys.executable, "-c", code], os.path.join(self.dir, "raw.log"), out=io.StringIO(), grace=0.1)
        self.assertEqual((status, text), (0, "done\n"))
        self.assertGreaterEqual(seconds, 0.5, "the wrapper waited for the command itself, not its EOF")


def _kill_quietly(pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


if __name__ == "__main__":
    unittest.main()
