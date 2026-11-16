# tako — iOS walkthrough result accounting tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import json
import subprocess
import unittest

from simtest_results import walkthrough_verdict


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
