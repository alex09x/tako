#!/usr/bin/env python3
# tako — Split the native e2e scenarios: tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""e2e_shards on made-up registries and logs, and on the real durations."""

import importlib.util
import os
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "e2e_shards", os.path.join(os.path.dirname(os.path.abspath(__file__)), "e2e_shards.py"))
shards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shards)

LIST = "default typing\ndefault split\nexplicit persist-live\ndefault zoom\ndefault ctl-tree\nexplicit kitty-icat\ndefault paste\n"
DUR = {"typing": 50, "split": 70, "zoom": 60, "ctl-tree": 360, "paste": 40}


class ShardTests(unittest.TestCase):
    def test_the_registry_keeps_explicit_only_scenarios_apart(self):
        default, explicit = shards.parse_list(LIST)
        self.assertEqual(default, ["typing", "split", "zoom", "ctl-tree", "paste"])
        self.assertEqual(explicit, ["persist-live", "kitty-icat"])

    def test_a_bad_or_duplicated_registry_line_is_refused(self):
        for text in ("default typing\ndefault typing\n", "default Typing\n", "typing\n", "explicit persist-live\n"):
            with self.assertRaises(shards.ShardError):
                shards.parse_list(text)

    def test_every_default_scenario_lands_in_exactly_one_shard(self):
        default, _ = shards.parse_list(LIST)
        for n in range(1, 7):
            out = shards.assign(default, DUR, n)
            self.assertEqual(len(out), n)
            shards.account(default, out)
            self.assertEqual(sorted(x for s in out for x in s), sorted(default))

    def test_the_longest_goes_alone_and_shards_keep_registry_order(self):
        default, _ = shards.parse_list(LIST)
        out = shards.assign(default, DUR, 2)
        self.assertIn(["ctl-tree"], out)
        self.assertIn(["typing", "split", "zoom", "paste"], out)

    def test_the_same_inputs_give_the_same_shards(self):
        default, _ = shards.parse_list(LIST)
        self.assertEqual(shards.assign(default, DUR, 3), shards.assign(list(default), dict(DUR), 3))

    def test_an_unmeasured_scenario_weighs_the_median(self):
        out = shards.assign(["a", "b", "c"], {"a": 10, "b": 30}, 2)
        self.assertEqual(out, [["b"], ["a", "c"]])

    def test_accounting_catches_a_lost_or_doubled_scenario(self):
        with self.assertRaises(shards.ShardError):
            shards.account(["a", "b"], [["a"], []])
        with self.assertRaises(shards.ShardError):
            shards.account(["a", "b"], [["a", "b"], ["b"]])

    def test_a_shard_passes_only_when_each_assigned_case_finished_ok_once(self):
        ok = "[result] typing ok\nnoise\n[result] zoom ok\n"
        self.assertEqual(shards.check_log(["typing", "zoom"], ok), [])
        self.assertEqual(shards.check_log(["typing", "zoom"], "[result] typing ok\n"), ["zoom: never finished"])
        self.assertEqual(shards.check_log(["typing"], "[result] typing FAIL boom\n"), ["typing: FAIL"])
        self.assertEqual(shards.check_log(["typing"], ok), ["zoom: ran but was not assigned to this shard"])
        self.assertEqual(shards.check_log(["typing"], "[result] typing ok\n[result] typing ok\n"),
                         ["typing: finished 2 times"])
        # A bare "ok" line, all a truncated name gives, is not a result.
        self.assertEqual(shards.check_log(["typing"], "ok    typing         x\n"), ["typing: never finished"])

    def test_the_cli_checks_a_shard_log(self):
        with tempfile.TemporaryDirectory() as d:
            lst, log, dur = (os.path.join(d, x) for x in ("list", "log", "dur.json"))
            with open(lst, "w") as f:
                f.write(LIST)
            with open(dur, "w") as f:
                f.write('{"scenarios": {"ctl-tree": {"seconds": 360}, "typing": {"seconds": 10}, '
                        '"split": {"seconds": 10}, "zoom": {"seconds": 10}, "paste": {"seconds": 10}}}')
            with open(log, "w") as f:
                f.write("[result] ctl-tree ok\n")
            args = ["--list", lst, "--durations", dur, "--shard", "1/2"]
            self.assertEqual(shards.main(["check", *args, "--log", log]), 0)
            self.assertEqual(shards.main(["check", *args[:-1], "2/2", "--log", log]), 1)
            self.assertEqual(shards.main(["assign", *args[:-1], "3/2"]), 2)

    def test_the_plan_reports_the_weights_the_assignment_used(self):
        import contextlib, io
        with tempfile.TemporaryDirectory() as d:
            lst, dur = os.path.join(d, "list"), os.path.join(d, "dur.json")
            with open(lst, "w") as f:
                f.write("default a\ndefault b\ndefault c\n")
            with open(dur, "w") as f:
                f.write('{"scenarios": {"a": {"seconds": 60}, "b": {"seconds": 180}}}')
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(shards.main(["plan", "--list", lst, "--durations", dur, "--shards", "1"]), 0)
        # c is dealt at the median (120 s): 60 + 180 + 120 = 6 min, not 4.
        self.assertIn("~6.0 min as dealt (2 measured, 1 at the median)", out.getvalue())

    def test_a_shard_command_needs_exactly_its_own_arguments(self):
        with tempfile.TemporaryDirectory() as d:
            lst = os.path.join(d, "list")
            with open(lst, "w") as f:
                f.write("default a\ndefault b\n")
            for argv in (["assign", "--list", lst, "--shards", "2"],
                         ["check", "--list", lst, "--shards", "2", "--log", lst],
                         ["check", "--list", lst, "--shard", "2/2"],
                         ["assign", "--list", lst, "--shard", "1/2", "--shards", "2"],
                         ["plan", "--list", lst],
                         ["plan", "--list", lst, "--shard", "1/2"]):
                self.assertEqual(shards.main(argv), 2, argv)

    def test_an_empty_shard_is_refused_rather_than_printed_as_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            lst = os.path.join(d, "list")
            with open(lst, "w") as f:
                f.write("default typing\ndefault split\n")
            self.assertEqual(shards.main(["assign", "--list", lst, "--shard", "2/2"]), 0)
            self.assertEqual(shards.main(["assign", "--list", lst, "--shard", "3/3"]), 2)

    def test_the_measured_durations_cover_most_of_the_default_registry(self):
        durations = shards.load_durations()
        self.assertGreaterEqual(len(durations), 60)
        self.assertTrue(all(v > 0 for v in durations.values()))
        self.assertFalse([n for n in durations if n.startswith("persist-")])


if __name__ == "__main__":
    unittest.main()
