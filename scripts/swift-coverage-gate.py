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
    TOP_LEVEL_SUITE_RE = re.compile(
        r"^Test Suite ['\"](Selected tests|All tests|.*\.xctest)['\"] (passed|failed)",
        re.IGNORECASE,
    )
    SWIFT_TESTING_SUMMARY_RE = re.compile(
        r"^Test run with \d+ test(s)? (passed|failed)",
        re.IGNORECASE,
    )
    XCTEST_EXECUTED_RE = re.compile(
        r"^\s*Executed \d+ test",
        re.IGNORECASE,
    )

    def __init__(self):
        self.finished = False
        self._top_level_suite_seen = False

    def feed_line(self, line: str) -> None:
        clean = self.ANSI_ESCAPE.sub("", line).strip()
        if not clean:
            return

        if self.SWIFT_TESTING_SUMMARY_RE.search(clean):
            self.finished = True
            return

        if clean.startswith("Test Suite "):
            if self.TOP_LEVEL_SUITE_RE.match(clean):
                self._top_level_suite_seen = True
                self.finished = True
            else:
                self._top_level_suite_seen = False
            return

        if self._top_level_suite_seen and self.XCTEST_EXECUTED_RE.match(clean):
            self.finished = True
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

    def test_xctest_bundle_summary(self):
        lines = [
            "Test Suite 'TakoCoreUITests.xctest' started at 2026-10-09 10:00:00.000.",
            "Test Suite 'TakoCoreUITests.xctest' passed at 2026-10-09 10:00:00.010.",
            "\t Executed 50 tests, with 0 failures (0 unexpected) in 1.000 (1.000) seconds",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_swift_testing_summary_passed(self):
        lines = [
            "Building for debugging...",
            "Test run with 150 tests passed after 0.456 seconds.",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_swift_testing_summary_failed(self):
        lines = [
            "Building for debugging...",
            "Test run with 150 tests failed after 0.456 seconds.",
        ]
        tracker = TestCompletionTracker()
        for l in lines:
            tracker.feed_line(l)
        self.assertTrue(tracker.finished)

    def test_ansi_escaped_top_level_summary(self):
        lines = [
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
