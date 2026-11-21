# tako — iOS walkthrough result accounting tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import json
import subprocess
import unittest

from simtest_results import resize_verdict, walkthrough_verdict


def dump(*server, grid="47x24"):
    """A dump as LaunchProbe writes it, the server transcript in both sections."""
    head = "status: connected\ntitle: 127.0.0.1 · ssh\n" + (f"grid: {grid} (view {grid})\n" if grid else "")
    body = "\n".join(server)
    return head + "── on screen ──\n" + body + "\n── buffer ──\n" + body + "\n"


class ResizeVerdictTests(unittest.TestCase):
    def test_the_default_initial_size_then_the_drawn_grid_passes(self):
        self.assertEqual(resize_verdict(dump("PTY xterm-256color 80x24", "RESIZE 47x24")), [])

    def test_an_already_laid_out_initial_size_then_the_drawn_grid_passes(self):
        # CI 44003398521: layout ran before the PTY request.
        self.assertEqual(resize_verdict(dump("PTY xterm-256color 47x23", "RESIZE 47x24")), [])

    def test_a_true_80x24_grid_is_not_rejected_as_stale(self):
        self.assertEqual(resize_verdict(dump("PTY xterm-256color 47x23", "RESIZE 80x24", grid="80x24")), [])

    def test_a_final_size_that_is_not_the_drawn_grid_fails(self):
        for final in ["RESIZE 47x23", "RESIZE 46x24"]:
            with self.subTest(final=final):
                self.assertTrue(resize_verdict(dump("PTY xterm-256color 80x24", final)))

    def test_a_stale_80x24_fails_even_if_the_drawn_grid_follows(self):
        self.assertTrue(resize_verdict(dump("PTY xterm-256color 80x24", "RESIZE 80x24", "RESIZE 47x24")))
        self.assertTrue(resize_verdict(dump("PTY xterm-256color 80x24", "RESIZE 80x24")))

    def test_missing_grid_pty_or_resize_fails_closed(self):
        self.assertIn("the app reported no core and view grid",
                      resize_verdict(dump("PTY xterm-256color 80x24", "RESIZE 47x24", grid=None)))
        self.assertIn("the server saw no PTY request", resize_verdict(dump("RESIZE 47x24")))
        self.assertIn("the server saw no RESIZE", resize_verdict(dump("PTY xterm-256color 47x24")))
        self.assertTrue(resize_verdict(""))

    def test_the_view_grid_must_be_present_and_equal_to_the_core(self):
        ok = dump("PTY xterm-256color 80x24", "RESIZE 47x24")
        for header in ["grid: 47x24 (view none)", "grid: 47x24 (view 46x24)", "grid: 47x24",
                       "grid: 47x24 (view 47x)", "grid: 47x24 (view 0x0)"]:
            with self.subTest(header=header):
                text = ok.replace("grid: 47x24 (view 47x24)", header)
                self.assertNotEqual(text, ok)
                self.assertTrue(resize_verdict(text))

    def test_the_visible_fragment_never_stands_in_for_the_buffer(self):
        # Without the buffer section, the on-screen text alone would hide a
        # stale RESIZE 80x24 that scrolled off.
        head = "status: connected\ntitle: t\ngrid: 47x24 (view 47x24)\n"
        on_screen = "── on screen ──\nPTY xterm-256color 80x24\nRESIZE 47x24\n"
        self.assertIn("the dump has no buffer section", resize_verdict(head + on_screen))
        self.assertIn("the dump has no buffer section", resize_verdict(head + on_screen + "── buffer ──\n  \n"))
        # The buffer, not the screen, decides: a stale 80x24 only in the buffer fails.
        full = head + on_screen + "── buffer ──\nPTY xterm-256color 80x24\nRESIZE 80x24\nRESIZE 47x24\n"
        self.assertTrue(resize_verdict(full))

    def test_zero_sizes_fail(self):
        self.assertTrue(resize_verdict(dump("PTY xterm-256color 0x24", "RESIZE 0x24", grid="0x24")))
        self.assertTrue(resize_verdict(dump("PTY xterm-256color 47x0", "RESIZE 47x24")))


class WalkthroughResultsTests(unittest.TestCase):
    def verdict(self, *, build_rc=0, summary_rc=0, summary=None, raw=None):
        if summary is None:
            summary = {"passedTests": 1, "failedTests": 0, "testFailures": []}
        return walkthrough_verdict(
            subprocess.CompletedProcess([], build_rc, "build output", "build stderr"),
            subprocess.CompletedProcess([], summary_rc,
                                        json.dumps(summary) if raw is None else raw, ""))

    def test_a_successful_executed_walkthrough_passes(self):
        self.assertEqual(self.verdict(), {"passed": 1, "failed": []})

    def test_a_successful_summary_cannot_hide_a_failed_build(self):
        self.assertIn("xcodebuild exited 65", self.verdict(build_rc=65)["failed"])

    def test_a_missing_summary_fails_even_if_the_build_succeeds(self):
        result = self.verdict(summary_rc=1)
        self.assertEqual(result["passed"], 0)
        self.assertIn("xcresult summary exited 1", result["failed"])

    def test_zero_executed_or_invalid_counts_fail(self):
        for value in [0, -1, True, "1", None]:
            with self.subTest(value=value):
                self.assertTrue(self.verdict(summary={"passedTests": value, "failedTests": 0})["failed"])

    def test_a_failed_count_cannot_pass_without_failure_records(self):
        self.assertTrue(self.verdict(summary={"passedTests": 129, "failedTests": 1})["failed"])

    def test_the_failure_keeps_the_test_identifier(self):
        result = self.verdict(summary={"passedTests": 129, "failedTests": 1,
                                      "testFailures": [{"testName": "Walkthrough.testTrust",
                                                        "failureText": "Trust did not appear"}]})
        self.assertEqual(result["failed"], ["Walkthrough.testTrust: Trust did not appear"])

    def test_malformed_summary_and_failure_records_fail(self):
        for raw in ["not JSON", "{}", "[]", "null", '{"passedTests": 1, "failedTests": 0} extra']:
            with self.subTest(raw=raw):
                self.assertTrue(self.verdict(raw=raw)["failed"])
        for failures in ["bad", [None], [{}]]:
            with self.subTest(failures=failures):
                self.assertTrue(self.verdict(summary={"passedTests": 1, "failedTests": 0,
                                                     "testFailures": failures})["failed"])


if __name__ == "__main__":
    unittest.main()
