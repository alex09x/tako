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
import subprocess
import sys
import tempfile
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
            "logs = os.listdir('target/check-logs')\n"
            "assert len(logs) == 1, logs\n"
            "print('CHECKED', logs[0])\n")], capture_output=True, text=True, env=env, cwd=self.dir)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("CHECKED", r.stdout)
        self.assertIn("test result: ok. 3 passed", r.stdout)
        self.assertNotIn("\nwarning: x\n", r.stdout, "the warning stays in the per-check file")


if __name__ == "__main__":
    unittest.main()
