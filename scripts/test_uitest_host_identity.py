#!/usr/bin/env python3
#
# tako — Tests for the private UI-test host identity
# Copyright (c) 2026 Alexander Panasenko
#
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# python3 scripts/test_uitest_host_identity.py
#
# The wrapper cases run scripts/uitest.sh --build-only with stand-ins on PATH:
# a fake xcodebuild and a python3 shim whose snapshot/census answers are set per
# case. Nothing real is built, launched, inspected or removed.

import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uitest_host_identity as identity  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, "macos_uitests/TakoUITests/TakoUITests.entitlements")


def template() -> bytes:
    with open(TEMPLATE, "rb") as f:
        return f.read()


def fake_run(outputs: dict):
    """A stand-in for run_tool: the output for each tool, or a Refused for a
    failed one."""
    def run(argv, what):
        key = " ".join(argv[1:3]) if argv[0].endswith("lsappinfo") else "ps"
        answer = outputs[key]
        if isinstance(answer, Exception):
            raise answer
        return answer
    return run


PS = "\n".join([
    "    1 Mon Sep 21 23:49:34 2026     /sbin/launchd",
    "50943 Sat Nov 14 22:42:19 2026     /Users/u/Library/Application Support/com.tako-core.terminal.uitest/runtime/0.8.1/zmx",
    "  612 Sun Nov 15 09:00:01 2026     /Users/u/Library/Application Support/com.tako-core.terminal.uitest.run-1/runtime/zmx",
    "  700 Sun Nov  1 09:00:02 2026     /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
]) + "\n"
SUPPORT = "/Users/u/Library/Application Support/com.tako-core.terminal.uitest"


class EntitlementsTests(unittest.TestCase):
    def test_the_checked_in_template_is_the_shared_host_exactly(self):
        self.assertEqual(plistlib.loads(template()), identity.exceptions(identity.SHARED_HOST, identity.SHARED_SUITE))
        # The checked-in socket rule is the app's derivation, not a copied constant.
        self.assertIn("tako-ctl-75802249693a[.]sock", template().decode())
        self.assertEqual(identity.socket_hash(identity.SHARED_HOST), "75802249693a")

    def test_a_private_run_names_only_its_own_host_and_suite(self):
        out = plistlib.loads(identity.private_entitlements(template(), "run-1234"))
        host, suite = "com.tako-core.terminal.uitest.run-1234", "TAKO_UITEST_RUN_run-1234"
        self.assertEqual(out[identity.PREFERENCES], [host, suite])
        self.assertEqual(out[identity.HOME_RELATIVE], [f"/Library/Application Support/{host}/",
                                                       f"/Library/Saved Application State/{host}.savedState/"])
        self.assertEqual(out[identity.ABSOLUTE], ["/private/tmp/tkui/"])
        [rule] = out[identity.SBPL]
        self.assertIn(f"tako-ctl-{identity.socket_hash(host)}[.]sock$", rule)
        text = identity.private_entitlements(template(), "run-1234").decode()
        self.assertNotIn("75802249693a", text)
        self.assertNotIn("<string>com.tako-core.terminal.uitest</string>", text)
        self.assertNotIn("<string>TAKO_UI_TESTS</string>", text)
        self.assertNotIn("uitest/</string>", text)

    def test_suffixes_that_are_not_a_plain_private_name_are_refused(self):
        for bad in ["", "abc", "UPPER", "-lead", "has.dot", "has/slash", "a" * 33, "x*", "run 1"]:
            with self.assertRaises(identity.Refused, msg=bad):
                identity.private_entitlements(template(), bad)

    def test_an_unexpected_template_is_refused_not_rewritten(self):
        shared = identity.exceptions(identity.SHARED_HOST, identity.SHARED_SUITE)
        variants = []
        extra = dict(shared); extra["com.apple.security.app-sandbox"] = True; variants.append(extra)
        wider = dict(shared); wider[identity.PREFERENCES] = [identity.SHARED_HOST, identity.SHARED_SUITE, "*"]; variants.append(wider)
        moved = dict(shared); moved[identity.ABSOLUTE] = ["/"]; variants.append(moved)
        missing = dict(shared); del missing[identity.SBPL]; variants.append(missing)
        for variant in variants:
            with self.assertRaises(identity.Refused):
                identity.private_entitlements(plistlib.dumps(variant), "run-1234")


class ProcessTests(unittest.TestCase):
    def test_only_processes_inside_the_profile_are_its_own(self):
        self.assertEqual(identity.processes_under(SUPPORT, fake_run({"ps": PS})),
                         [[50943, "Sat Nov 14 22:42:19 2026", f"{SUPPORT}/runtime/0.8.1/zmx"]])
        self.assertEqual(identity.processes_under(SUPPORT + ".run-1", fake_run({"ps": PS})),
                         [[612, "Sun Nov 15 09:00:01 2026", f"{SUPPORT}.run-1/runtime/zmx"]])
        self.assertEqual(identity.processes_under("/nowhere", fake_run({"ps": PS})), [])

    def test_an_unreadable_process_table_is_an_error_not_an_absence(self):
        for listing in ["", "\n  \n", "garbage\n", PS + "12 not a date at all /bin/x\n",
                        PS + "x1 Mon Sep 21 23:49:34 2026     /bin/x\n", PS + "13 Mon Sep 21 23:49:34 2026\n"]:
            with self.assertRaises(identity.Refused, msg=repr(listing[-40:])):
                identity.processes_under(SUPPORT, fake_run({"ps": listing}))
        with self.assertRaises(identity.Refused):
            identity.processes_under(SUPPORT, fake_run({"ps": identity.Refused("ps exited 1")}))

    def test_apps_are_read_or_the_inspection_fails(self):
        none = {"find bundleid=x": ""}
        self.assertEqual(identity.running_pids("x", fake_run(none)), [])
        one = {"find bundleid=x": 'ASN:0x0-0x22022-"Tako":\n', "info -only": '"pid"=519\n'}
        self.assertEqual(identity.running_pids("x", fake_run(one)), [519])
        for broken in [{"find bundleid=x": "something unexpected\n"},
                       {"find bundleid=x": 'ASN:0x0-0x22022-"Tako":\n', "info -only": ""},
                       {"find bundleid=x": 'ASN:0x0-0x22022-"Tako":\n', "info -only": '"pid"=[ NULL ]\n'},
                       {"find bundleid=x": 'ASN:0x0-0x22022-"Tako":\n', "info -only": '"pid"=1\n"pid"=2\n'},
                       {"find bundleid=x": identity.Refused("lsappinfo find exited 1")},
                       {"find bundleid=x": 'ASN:0x0-0x22022-"Tako":\n',
                        "info -only": identity.Refused("lsappinfo info exited 1")}]:
            with self.assertRaises(identity.Refused, msg=repr(broken)):
                identity.running_pids("x", fake_run(broken))

    def test_the_census_reports_apps_and_runtimes_of_that_host_only(self):
        run = fake_run({"find bundleid=com.tako-core.terminal.uitest.run-1": "", "ps": PS})
        found = identity.census("com.tako-core.terminal.uitest.run-1", "/Users/u", run)
        self.assertEqual(found["apps"], [])
        self.assertEqual([row[0] for row in found["profile"]], [612])

    def test_tool_errors_name_the_tool_not_its_arguments(self):
        with self.assertRaises(identity.Refused) as caught:
            identity.run_tool(["/usr/bin/false", "bundleid=secret"], "lsappinfo find")
        self.assertNotIn("secret", str(caught.exception))
        self.assertEqual(identity.TOOL_ENV["LC_ALL"], "C")


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.root)

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def test_the_root_is_described_and_reading_changes_nothing(self):
        empty = self.path("empty")
        os.mkdir(empty)
        before = identity.describe(empty)
        self.assertEqual(set(before["entries"]), {"."})
        self.assertEqual(identity.describe(empty), before)
        os.chmod(empty, 0o700)
        os.chmod(empty, 0o755)
        restored = identity.describe(empty)
        os.chmod(empty, 0o700)
        self.assertNotEqual(identity.describe(empty), restored, "a root mode change must be visible")

    def test_link_targets_are_recorded_and_never_followed(self):
        for name in ("a", "b"):
            os.makedirs(self.path(name, "inside"))
            with open(self.path(name, "inside", "f"), "w") as f:
                f.write(name)
        os.symlink(self.path("a"), self.path("root-link"))
        root = identity.describe(self.path("root-link"))
        self.assertEqual(set(root["entries"]), {"."}, "a root link is recorded, not walked")
        self.assertEqual(root["entries"]["."]["link"], self.path("a"))
        os.remove(self.path("root-link"))
        os.symlink(self.path("b"), self.path("root-link"))
        self.assertNotEqual(identity.describe(self.path("root-link")), root, "retargeting the root link")

        os.makedirs(self.path("tree"))
        os.symlink(self.path("a"), self.path("tree", "child"))
        tree = identity.describe(self.path("tree"))
        self.assertEqual(set(tree["entries"]), {".", "child"}, "a linked directory is not walked")
        self.assertEqual(tree["entries"]["child"]["link"], self.path("a"))
        os.remove(self.path("tree", "child"))
        os.symlink(self.path("b"), self.path("tree", "child"))
        self.assertNotEqual(identity.describe(self.path("tree")), tree, "retargeting a child link")

    def test_content_changes_and_absence_are_visible(self):
        os.makedirs(self.path("a", "b"))
        with open(self.path("a", "b", "state.json"), "w") as f:
            f.write("{}")
        before = identity.describe(self.path("a"))
        self.assertIn("sha256", before["entries"]["b/state.json"])
        with open(self.path("a", "b", "state.json"), "w") as f:
            f.write("{1}")
        self.assertNotEqual(identity.describe(self.path("a")), before)
        self.assertEqual(identity.describe(self.path("absent")), {"exists": False})

    def test_an_unreadable_directory_fails_the_snapshot(self):
        os.makedirs(self.path("p", "locked"))
        os.chmod(self.path("p", "locked"), 0)
        try:
            with self.assertRaises(identity.Refused):
                identity.describe(self.path("p"))
        finally:
            os.chmod(self.path("p", "locked"), 0o755)


FAKE_IDENTITY = textwrap.dedent("""\
    import json, os, sys
    sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts"))
    command = sys.argv[1]
    state = os.environ["FAKE_STATE"]
    count = os.path.join(state, command + ".count")
    n = int(open(count).read()) + 1 if os.path.exists(count) else 1
    open(count, "w").write(str(n))
    answer = os.environ.get(f"FAKE_{command.upper()}_{n}", "same" if command == "snapshot" else "empty")
    out = sys.argv[sys.argv.index("--out") + 1]
    if answer == "broken":
        sys.exit(2)
    if command == "snapshot":
        json.dump({"shared": answer}, open(out, "w"))
        sys.exit(0)
    found = {"apps": [], "profile": [[612, "Sun Nov 15 09:00:01 2026", "zmx"]] if answer == "busy" else []}
    json.dump(found, open(out, "w"))
    sys.exit(3 if answer == "busy" else 0)
""")


class WrapperTests(unittest.TestCase):
    """scripts/uitest.sh --host-id admission and outcome, with stand-ins only."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        bin_dir = os.path.join(self.tmp, "bin")
        os.mkdir(bin_dir)
        self.state = os.path.join(self.tmp, "state")
        os.mkdir(self.state)
        with open(os.path.join(self.tmp, "fake_identity.py"), "w") as f:
            f.write(FAKE_IDENTITY)
        self.write(bin_dir, "python3", f"""\
            #!/bin/bash
            if [ "$1" = scripts/uitest_host_identity.py ]; then
                case "$2" in snapshot|census) exec {sys.executable} "{self.tmp}/fake_identity.py" "${{@:2}}";; esac
            fi
            exec {sys.executable} "$@"
            """)
        self.write(bin_dir, "xcodebuild", f"""\
            #!/bin/bash
            echo called >> "{self.state}/xcodebuild"
            echo "** TEST BUILD SUCCEEDED **"
            """)
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", REPO=ROOT, FAKE_STATE=self.state,
                        TAKO_GUI_LOCK=os.path.join(self.tmp, "gui.lock"))
        for key in ("TAKO_REMOTE_EXEC", "SSH_CLIENT", "SSH_CONNECTION"):
            self.env.pop(key, None)
        self.run_dirs = []

    def tearDown(self):
        for run_dir in self.run_dirs:
            shutil.rmtree(run_dir, ignore_errors=True)
        shutil.rmtree(self.tmp)

    @staticmethod
    def write(directory, name, body):
        path = os.path.join(directory, name)
        with open(path, "w") as f:
            f.write(textwrap.dedent(body))
        os.chmod(path, 0o755)

    def wrapper(self, **answers):
        env = dict(self.env, **{f"FAKE_{key.upper()}": value for key, value in answers.items()})
        done = subprocess.run(["bash", "scripts/uitest.sh", "--local", "--host-id=wrap-test", "--build-only"],
                              cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
        for line in done.stdout.splitlines():
            if line.startswith("Run evidence: "):
                self.run_dirs.append(os.path.join(ROOT, line.split(": ", 1)[1]))
        built = os.path.exists(os.path.join(self.state, "xcodebuild"))
        return done.returncode, built, done.stdout + done.stderr

    def test_a_clean_private_host_builds_and_succeeds(self):
        code, built, out = self.wrapper()
        self.assertEqual((code, built), (0, True), out)

    def test_a_leftover_runtime_refuses_admission_with_evidence(self):
        code, built, out = self.wrapper(census_1="busy")
        self.assertEqual((code, built), (2, False), out)
        evidence = os.path.join(self.run_dirs[0], "private-host-census-before.json")
        with open(evidence) as f:
            self.assertEqual(json.load(f)["profile"][0][0], 612)

    def test_an_unreadable_census_refuses_admission(self):
        self.assertEqual(self.wrapper(census_1="broken")[:2], (2, False))

    def test_an_unreadable_shared_snapshot_refuses_admission(self):
        self.assertEqual(self.wrapper(snapshot_1="broken")[:2], (2, False))

    def test_a_runtime_left_after_the_run_fails_it(self):
        code, built, out = self.wrapper(census_2="busy")
        self.assertEqual((code, built), (5, True), out)
        self.assertIn("left an app or a runtime behind", out)

    def test_an_unreadable_census_after_the_run_fails_it(self):
        self.assertEqual(self.wrapper(census_2="broken")[:2], (5, True))

    def test_a_shared_host_change_fails_the_run(self):
        self.assertEqual(self.wrapper(snapshot_2="changed")[:2], (4, True))

    def test_an_unreadable_shared_snapshot_after_the_run_fails_it(self):
        code, built, out = self.wrapper(snapshot_2="broken")
        self.assertEqual((code, built), (4, True), out)
        self.assertIn("its state is unknown", out, "an unread snapshot is not reported as a change")


if __name__ == "__main__":
    unittest.main()
