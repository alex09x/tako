#!/usr/bin/env python3
# tako — The macOS app self-test verdict cannot pass on an incomplete run
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
import contextlib
import io
import os
import tempfile
import unittest

from selftest_verdict import main, problems

ALL = ["app-selftest-keys", "app-selftest-input", "app-selftest-scroll", "app-selftest-frame"]


def log(*results, summary="tako e2e: ok"):
    return "\n".join(["noise"] + [f"[result] {name} {outcome}" for name, outcome in results] + [summary, ""])


GOOD = log(*[(name, "ok") for name in ALL])


class VerdictTests(unittest.TestCase):
    def test_every_requested_case_once_ok_passes(self):
        self.assertEqual(problems(0, GOOD, ALL), [])

    def test_a_nonzero_runner_status_cannot_pass(self):
        self.assertEqual(problems(1, GOOD, ALL), ["the runner exited with status 1"])

    def test_a_missing_summary_cannot_pass(self):
        text = log(*[(name, "ok") for name in ALL], summary="tako e2e: 1 FAILED")
        self.assertIn("the runner did not report `tako e2e: ok`", problems(0, text, ALL))

    def test_a_missing_result_cannot_pass(self):
        text = log(*[(name, "ok") for name in ALL[:3]])
        self.assertEqual(problems(0, text, ALL), ["no result for app-selftest-frame"])

    def test_a_failed_case_cannot_pass(self):
        text = log(("app-selftest-scroll", "FAIL"))
        self.assertEqual(problems(0, text, ["app-selftest-scroll"]), ["app-selftest-scroll failed"])

    def test_a_duplicate_result_cannot_pass(self):
        text = log(("app-selftest-scroll", "ok"), ("app-selftest-scroll", "ok"))
        self.assertEqual(problems(0, text, ["app-selftest-scroll"]), ["2 results for app-selftest-scroll"])

    def test_an_extra_result_cannot_pass(self):
        text = log(("app-selftest-scroll", "ok"), ("app-selftest-keys", "ok"))
        self.assertEqual(problems(0, text, ["app-selftest-scroll"]),
                         ["a result for app-selftest-keys, which was not requested"])

    def test_no_requested_case_cannot_pass(self):
        self.assertEqual(problems(0, log(), []), ["no case was requested"])

    def test_the_marker_is_printed_only_on_a_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "runner.log")
            with open(path, "w") as f:
                f.write(GOOD)
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(main(["--status", "0", "--log", path] + ALL), 0)
                self.assertEqual(main(["--status", "1", "--log", path] + ALL), 1)
                self.assertEqual(main(["--status", "0", "--log", path + ".missing"] + ALL), 1)
            self.assertEqual(out.getvalue(), "macapp self-test: ok\n")
            self.assertEqual(err.getvalue().count("macapp self-test: FAILED"), 2)


if __name__ == "__main__":
    unittest.main()
