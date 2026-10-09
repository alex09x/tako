#!/usr/bin/env python3
"""Fail when any Swift source file's line coverage is below a floor.

    scripts/swift-coverage-gate.py                         # all of TakoCoreUI, floor 80%
    scripts/swift-coverage-gate.py --min 85 TakoCoreUI/PTYDeliveryPump.swift
    scripts/swift-coverage-gate.py --module TakoKit --module TakoApp/_TakoShim

Runs the whole Swift suite through scripts/swift-test.sh (which rebuilds the
engine when it is stale) with coverage on, and reads SwiftPM's coverage JSON.
Generated bindings are never counted.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def extract_module(path: str) -> str:
    norm = os.path.normpath(path).strip().lstrip(os.sep)
    if norm.startswith("./"):
        norm = norm[2:]
    parts = norm.split(os.sep)
    return parts[0] if parts else ""


def compute_effective_modules(files: list[str], modules: list[str] | None) -> set[str]:
    if files:
        mods = {extract_module(f) for f in files if f.strip()}
        mods.discard("")
        return mods
    return set(modules or ["TakoCoreUI"])


def should_filter_coreui(effective_modules: set[str]) -> bool:
    return effective_modules == {"TakoCoreUI"}


class TestCompletionTracker:
    ANSI_ESCAPE = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")

    # Root XCTest suite starts: 'Selected tests' or 'All tests'
    XCTEST_ROOT_START_RE = re.compile(
        r"^Test Suite ['\"](Selected tests|All tests)['\"] started at",
        re.IGNORECASE,
    )
    # Standalone bundle suite start: fallback only if no enclosing All/Selected suite
    XCTEST_BUNDLE_START_RE = re.compile(
        r"^Test Suite ['\"](.*\.xctest)['\"] started at",
        re.IGNORECASE,
    )
    # XCTest suite completion: captures suite name and status (passed/failed)
    XCTEST_SUITE_END_RE = re.compile(
        r"^Test Suite ['\"](.*)['\"] (passed|failed) at",
        re.IGNORECASE,
    )
    # XCTest Executed summary line
    XCTEST_EXECUTED_RE = re.compile(
        r"^\s*Executed \d+ test",
        re.IGNORECASE,
    )

    # Swift Testing phase start
    SWIFT_TESTING_START_RE = re.compile(
        r"^(?:[◇◆●\*\-]\s+)?Test run started\.",
        re.IGNORECASE,
    )
    # Swift Testing phase completion (supports status glyphs like ✔ / ✘ and optional suite count)
    SWIFT_TESTING_SUMMARY_RE = re.compile(
        r"^(?:[✔✘✖✕\u2713\u2714\u2717\u2718\*\-]\s+)?Test run with \d+ test(?:s)?(?:\s+in\s+\d+\s+suite(?:s)?)?\s+(passed|failed)\s+after\s+",
        re.IGNORECASE,
    )

    def __init__(self):
        self.xctest_started = False
        self.xctest_root_suite: str | None = None
        self._xctest_root_status_seen = False
        self.xctest_completed = False

        self.swift_testing_started = False
        self.swift_testing_completed = False

    @property
    def finished(self) -> bool:
        if not self.xctest_started and not self.swift_testing_started:
            return False
        if self.xctest_started and not self.xctest_completed:
            return False
        if self.swift_testing_started and not self.swift_testing_completed:
            return False
        return True

    def feed_line(self, line: str) -> None:
        clean = self.ANSI_ESCAPE.sub("", line).strip()
        if not clean:
            return

        # 1. Swift Testing phase start
        if self.SWIFT_TESTING_START_RE.search(clean):
            self.swift_testing_started = True
            self.swift_testing_completed = False
            return

        # 2. Swift Testing summary line
        if self.SWIFT_TESTING_SUMMARY_RE.search(clean):
            self.swift_testing_started = True
            self.swift_testing_completed = True
            return

        # 3. XCTest root suite start detection
        root_start = self.XCTEST_ROOT_START_RE.match(clean)
        if root_start:
            self.xctest_started = True
            self.xctest_root_suite = root_start.group(1)
            self._xctest_root_status_seen = False
            self.xctest_completed = False
            return

        bundle_start = self.XCTEST_BUNDLE_START_RE.match(clean)
        if bundle_start:
            self.xctest_started = True
            if self.xctest_root_suite is None:
                self.xctest_root_suite = bundle_start.group(1)
                self._xctest_root_status_seen = False
                self.xctest_completed = False
            return

        # 4. XCTest suite passed/failed lines
        suite_end = self.XCTEST_SUITE_END_RE.match(clean)
        if suite_end:
            if self.xctest_root_suite and suite_end.group(1) == self.xctest_root_suite:
                self._xctest_root_status_seen = True
            else:
                self._xctest_root_status_seen = False
            return

        # 5. XCTest Executed summary line
        if self._xctest_root_status_seen and self.XCTEST_EXECUTED_RE.match(clean):
            self.xctest_completed = True
            self._xctest_root_status_seen = False
            return


class TestSwiftCoverageGate(unittest.TestCase):
    def test_truncated_class_summary_rejected(self):
        lines = [
            "Test Suite 'Selected tests' started at 2026-10-09 10:00:00.000.",
            "Test Suite 'TerminalCellHitTests' started at 2026-10-09 10:00:00.001.",
            "Test Case '-[TerminalCellHitTests testHit]' passed (0.002 seconds).",
            "Test Suite 'TerminalCellHitTests' passed at 2026-10-09 10:00:00.003.",
            "\t Executed 1 test, with 0 failures (0 unexpected) in 0.002 (0.002) seconds",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertFalse(tracker.finished)

    def test_nested_bundle_completion_does_not_substitute_for_enclosing_run(self):
        lines = [
            "Test Suite 'All tests' started at 2026-08-19 15:18:45.735.",
            "Test Suite 'TakoCoreUIPackageTests.xctest' started at 2026-08-19 15:18:45.737.",
            "Test Suite 'TakoCoreUIPackageTests.xctest' passed at 2026-08-19 15:18:47.495.",
            "\t Executed 104 tests, with 0 failures (0 unexpected) in 1.739 (1.758) seconds",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertFalse(tracker.finished)

    def test_xctest_completed_followed_by_truncated_swift_testing_rejected(self):
        lines = [
            "Test Suite 'All tests' started at 2026-08-19 15:18:45.735.",
            "Test Suite 'TakoCoreUIPackageTests.xctest' started at 2026-08-19 15:18:45.737.",
            "Test Suite 'TakoCoreUIPackageTests.xctest' passed at 2026-08-19 15:18:47.495.",
            "\t Executed 104 tests, with 0 failures (0 unexpected) in 1.739 (1.758) seconds",
            "Test Suite 'All tests' passed at 2026-08-19 15:18:47.495.",
            "\t Executed 104 tests, with 0 failures (0 unexpected) in 1.739 (1.760) seconds",
            "◇ Test run started.",
            "↳ Testing Library Version: 1501",
            "◇ Suite SplitTreeTests started.",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertFalse(tracker.finished)

    def test_real_swift_testing_summary_from_log_passed(self):
        lines = [
            "◇ Test run started.",
            "✔ Test run with 282 tests in 24 suites passed after 1.947 seconds.",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_real_swift_testing_summary_from_log_failed(self):
        lines = [
            "◇ Test run started.",
            "✘ Test run with 282 tests in 24 suites failed after 1.947 seconds.",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_mixed_framework_full_run_accepted(self):
        lines = [
            "Test Suite 'All tests' started at 2026-08-19 15:18:45.735.",
            "Test Suite 'TakoCoreUIPackageTests.xctest' started at 2026-08-19 15:18:45.737.",
            "Test Suite 'TakoCoreUIPackageTests.xctest' passed at 2026-08-19 15:18:47.495.",
            "\t Executed 104 tests, with 0 failures (0 unexpected) in 1.739 (1.758) seconds",
            "Test Suite 'All tests' passed at 2026-08-19 15:18:47.495.",
            "\t Executed 104 tests, with 0 failures (0 unexpected) in 1.739 (1.760) seconds",
            "◇ Test run started.",
            "↳ Testing Library Version: 1501",
            "✔ Suite SplitTreeTests passed after 0.123 seconds.",
            "✔ Test run with 282 tests in 24 suites passed after 1.947 seconds.",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_xctest_selected_tests_full_summary(self):
        lines = [
            "Test Suite 'Selected tests' started at 2026-10-09 10:00:00.000.",
            "Test Suite 'TerminalCellHitTests' passed at 2026-10-09 10:00:00.003.",
            "\t Executed 1 test, with 0 failures (0 unexpected) in 0.002 (0.002) seconds",
            "Test Suite 'Selected tests' passed at 2026-10-09 10:00:00.010.",
            "\t Executed 1 test, with 0 failures (0 unexpected) in 0.002 (0.010) seconds",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_xctest_all_tests_summary(self):
        lines = [
            "Test Suite 'All tests' started at 2026-10-09 10:00:00.000.",
            "Test Suite 'All tests' passed at 2026-10-09 10:00:00.010.",
            "\t Executed 50 tests, with 0 failures (0 unexpected) in 1.000 (1.000) seconds",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_xctest_standalone_bundle_summary(self):
        lines = [
            "Test Suite 'TakoCoreUITests.xctest' started at 2026-10-09 10:00:00.000.",
            "Test Suite 'TakoCoreUITests.xctest' passed at 2026-10-09 10:00:00.010.",
            "\t Executed 50 tests, with 0 failures (0 unexpected) in 1.000 (1.000) seconds",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_ansi_escaped_top_level_summary(self):
        lines = [
            "\x1b[1mTest Suite 'Selected tests' started at 2026-10-09 10:00:00.000.\x1b[0m\n",
            "\x1b[1mTest Suite 'Selected tests' passed at 2026-10-09 10:00:00.010.\x1b[0m\n",
            "\t Executed 1 test, with 0 failures\n",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_effective_modules_filtering(self):
        self.assertEqual(compute_effective_modules([], None), {"TakoCoreUI"})
        self.assertTrue(should_filter_coreui(compute_effective_modules([], None)))

        self.assertEqual(compute_effective_modules(["TakoCoreUI/PTYDeliveryPump.swift"], None), {"TakoCoreUI"})
        self.assertTrue(should_filter_coreui(compute_effective_modules(["TakoCoreUI/PTYDeliveryPump.swift"], None)))

        self.assertEqual(compute_effective_modules(["./TakoCoreUI/Renderer/MetalRenderer.swift"], None), {"TakoCoreUI"})
        self.assertTrue(should_filter_coreui(compute_effective_modules(["./TakoCoreUI/Renderer/MetalRenderer.swift"], None)))

        self.assertFalse(should_filter_coreui(compute_effective_modules(["TakoApp/AppDelegate.swift"], None)))
        self.assertFalse(should_filter_coreui(compute_effective_modules([], ["TakoKit"])))
        self.assertFalse(should_filter_coreui(compute_effective_modules(["TakoCoreUI/Foo.swift", "TakoApp/Bar.swift"], None)))

    def test_actual_log_file_full_completion(self):
        log_path = os.path.join(ROOT, "target/swift-final-recheck.log")
        if not os.path.exists(log_path):
            return
        tracker = TestCompletionTracker()
        with open(log_path, "r", errors="replace") as f:
            for line in f:
                tracker.feed_line(line)
        self.assertTrue(tracker.finished)
        self.assertTrue(tracker.xctest_completed)
        self.assertTrue(tracker.swift_testing_completed)

    def test_actual_log_file_truncated_rejection(self):
        log_path = os.path.join(ROOT, "target/swift-final-recheck.log")
        if not os.path.exists(log_path):
            return
        tracker = TestCompletionTracker()
        with open(log_path, "r", errors="replace") as f:
            for idx, line in enumerate(f, 1):
                if idx > 270:
                    break
                tracker.feed_line(line)
        self.assertFalse(tracker.finished)
        self.assertTrue(tracker.xctest_completed)
        self.assertFalse(tracker.swift_testing_completed)



def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--min", type=float, default=80.0, help="line coverage floor, percent")
    parser.add_argument("--module", action="append", help="Sources/<dir> to check when no files are named; repeatable (default TakoCoreUI)")
    parser.add_argument("--self-test", action="store_true", help="run log parser and module derivation unit tests and exit")
    parser.add_argument("files", nargs="*", help="paths relative to swift/Sources to check")
    args = parser.parse_args()

    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestSwiftCoverageGate)
        runner = unittest.TextTestRunner(verbosity=2)
        result = runner.run(suite)
        sys.exit(0 if result.wasSuccessful() else 1)

    effective_modules = compute_effective_modules(args.files, args.module)

    # A Swift Testing or XCTest run whose main run loop is stopped by something under test
    # ends early with exit status 0, so the exit status alone would pass a run
    # that skipped half its tests. Its closing summary line is the proof that it finished.
    test_cmd = [os.path.join(ROOT, "scripts/swift-test.sh"), "--enable-code-coverage"]
    if should_filter_coreui(effective_modules):
        test_cmd += ["--filter", "TakoCoreUITests"]

    proc = subprocess.Popen(
        test_cmd,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    tracker = TestCompletionTracker()
    for line in proc.stdout:
        sys.stdout.write(line)
        tracker.feed_line(line)

    if proc.wait() != 0:
        sys.exit(f"swift-coverage-gate: the Swift suite failed (exit {proc.returncode})")
    if not tracker.finished:
        sys.exit("swift-coverage-gate: the test run ended without its top-level summary; it stopped early")
    path = subprocess.run(
        ["swift", "test", "--show-codecov-path"],
        cwd=os.path.join(ROOT, "swift"),
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()

    failed = False
    checked = 0
    for entry in json.load(open(path))["data"][0]["files"]:
        name = entry["filename"]
        if "/Sources/" not in name or "/Generated/" in name:
            continue
        rel = name.split("/Sources/", 1)[1]
        if args.files:
            if rel not in args.files:
                continue
        elif not any(rel.startswith(m + "/") for m in effective_modules):
            continue
        lines = entry["summary"]["lines"]
        pct = lines["percent"] if lines["count"] else 100.0
        ok = pct >= args.min
        failed |= not ok
        checked += 1
        print(f"{'ok  ' if ok else 'FAIL'} {pct:6.2f}%  {rel}")

    if checked == 0:
        sys.exit("swift-coverage-gate: nothing matched")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
