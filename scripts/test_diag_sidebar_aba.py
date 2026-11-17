#!/usr/bin/env python3
# tako — Sidebar diagnosis evidence contracts
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
import unittest

from diag_sidebar_aba import validate_case, verify_reseal


def log(verdict="ok", mode="off"):
    lines = [f"[result] sidebar-switch-speed {verdict}",
             f"[timing activity] latencyCritical {mode}",
             "owned processes: 5 all gone",
             "owner history: unchanged since before the first launch"]
    lines += [f"[timing boundary] name SwA {i}" for i in range(15)]
    lines += ["[timing windows] SwA before=[1] after=[2]"] * 15
    if verdict == "FAIL":
        lines.append("a sidebar switch took 309 ms to reach the screen")
    return "\n".join(lines)


class EvidenceTests(unittest.TestCase):
    def test_a_performance_failure_is_retained_as_a_failure(self):
        self.assertEqual(validate_case(log(), 0, "off"), "ok")
        self.assertEqual(validate_case(log("FAIL", "on"), 1, "on"), "FAIL")

    def test_missing_duplicate_or_foreign_results_are_refused(self):
        for text in [log().replace("[result]", "[missing]"),
                     log() + "\n[result] sidebar-switch-speed ok",
                     log().replace("sidebar-switch-speed", "another-case")]:
            with self.subTest(text=text[:40]), self.assertRaises(AssertionError):
                validate_case(text, 0, "off")

    def test_partial_unsafe_and_unowned_observations_are_refused(self):
        for text in [log().replace("[timing boundary]", "[missing]", 1),
                     log().replace("after=[2]", "after=[]", 1),
                     log().replace("5 all gone", "5 not proven"),
                     log().replace("unchanged since", "changed since"),
                     log() + "\n[timing model] unavailable: timeout"]:
            with self.subTest(text=text[:40]), self.assertRaises(AssertionError):
                validate_case(text, 0, "off")

    def test_unexpected_failures_and_wrong_modes_are_refused(self):
        with self.assertRaises(AssertionError):
            validate_case(log("FAIL").replace("a sidebar switch took", "ownership failed"), 1, "off")
        with self.assertRaises(AssertionError):
            validate_case(log(), 0, "on")
        with self.assertRaises(AssertionError):
            validate_case(log(), 1, "off")

    def test_reseal_changes_only_the_identity_and_signature(self):
        before = {"Contents/Info.plist": "old", "Contents/MacOS/Tako": "old", "resource": "same"}
        after = dict(before, **{"Contents/Info.plist": "new", "Contents/MacOS/Tako": "signed"})
        self.assertEqual(len(verify_reseal(before, after)), 2)
        for bad in [dict(after, resource="changed"), dict(after, added="file")]:
            with self.assertRaises(AssertionError):
                verify_reseal(before, bad)


if __name__ == "__main__":
    unittest.main()
