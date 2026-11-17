#!/usr/bin/env python3
# tako — The self-test wrapper on a fake runner: identity, logs, tee status
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Runs the real scripts/selftest-macapp.sh in a scratch checkout whose
e2e-macapp.sh is a fake that records what it was given; no app is launched."""
import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE_RUNNER = """#!/usr/bin/env bash
plist_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
printf '%s\\n' "$APP" "$TAKO_BUNDLE_ID" "$*" "$plist_id" >> target/runner-calls
sleep 0.3
if [ -n "${FAKE_RUNNER_FAIL:-}" ]; then
    for name in "$@"; do echo "[result] $name FAIL"; done
    echo "tako e2e: $# FAILED"
    exit 1
fi
for name in "$@"; do echo "[result] $name ok"; done
echo "tako e2e: ok"
"""


class WrapperTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = os.path.realpath(temporary.name)
        scripts = os.path.join(self.root, "scripts")
        os.makedirs(scripts)
        for name in ("selftest-macapp.sh", "selftest_verdict.py", "app_locations.py"):
            shutil.copy2(os.path.join(HERE, name), scripts)
        runner = os.path.join(scripts, "e2e-macapp.sh")
        with open(runner, "w") as f:
            f.write(FAKE_RUNNER)
        os.chmod(runner, 0o755)

    def app(self, identifier):
        app = os.path.join(self.root, "apps", identifier, "Tako.app")
        os.makedirs(os.path.join(app, "Contents/MacOS"))
        # Contents only: /usr/bin/true carries system flags a copy may not keep.
        shutil.copyfile("/usr/bin/true", os.path.join(app, "Contents/MacOS/Tako"))
        os.chmod(os.path.join(app, "Contents/MacOS/Tako"), 0o755)
        with open(os.path.join(app, "Contents/Info.plist"), "wb") as f:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "Tako",
                           "CFBundlePackageType": "APPL"}, f)
        return app

    def start(self, app, *args, env=None):
        environ = {k: v for k, v in os.environ.items() if k != "TAKO_BUNDLE_ID"}
        environ.update(APP=app, **(env or {}))
        return subprocess.Popen([os.path.join(self.root, "scripts/selftest-macapp.sh"), *args], cwd=self.root,
                                env=environ, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def finish(self, process):
        out, err = process.communicate(timeout=60)
        return process.returncode, out, err

    def calls(self):
        path = os.path.join(self.root, "target/runner-calls")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            lines = f.read().splitlines()
        return [lines[i:i + 4] for i in range(0, len(lines), 4)]

    def test_a_prepared_bundle_runs_as_itself(self):
        app = self.app("com.tako-core.terminal.e2e")
        rc, out, _ = self.finish(self.start(app, "--scroll-only"))
        self.assertEqual(rc, 0)
        self.assertIn("macapp self-test: ok", out)
        self.assertEqual(self.calls(), [[app, "com.tako-core.terminal.e2e", "app-selftest-scroll",
                                         "com.tako-core.terminal.e2e"]])

    def test_an_explicit_mismatch_fails_before_anything_runs(self):
        app = self.app("com.tako-core.terminal.e2e")
        rc, _, err = self.finish(self.start(app, env={"TAKO_BUNDLE_ID": "com.tako-core.terminal.ci"}))
        self.assertEqual(rc, 1)
        self.assertIn("nothing was launched", err)
        self.assertEqual(self.calls(), [])

    def test_the_production_identifier_runs_only_as_a_disposable_copy(self):
        app = self.app("com.tako-core.terminal")
        plist = os.path.join(app, "Contents/Info.plist")
        def digest():
            with open(plist, "rb") as f:
                return hashlib.sha256(f.read()).hexdigest()
        before = digest()
        copies = os.path.join(self.root, "target/selftest-copies")
        os.makedirs(os.path.join(copies, "run.Older1"))  # someone else's: never removed
        rc, out, _ = self.finish(self.start(app, "--scroll-only"))
        self.assertEqual(rc, 0, out)
        [(ran, identifier, names, ran_as)] = self.calls()
        self.assertNotEqual(ran, app)
        self.assertTrue(identifier.startswith("com.tako-core.terminal.e2e-selftest-"), identifier)
        self.assertEqual(ran_as, identifier, "the copy was resealed under the identifier the runner got")
        self.assertEqual(digest(), before, "the original is untouched")
        self.assertTrue(ran.startswith(copies + "/"))
        self.assertFalse(os.path.exists(os.path.dirname(ran)), "a passing run removes its own copy")
        self.assertIn("removed its disposable copy", out)
        self.assertTrue(os.path.isdir(os.path.join(copies, "run.Older1")))

    def test_a_failed_run_keeps_its_copy_and_says_where(self):
        app = self.app("com.tako-core.terminal")
        rc, _, err = self.finish(self.start(app, "--scroll-only", env={"FAKE_RUNNER_FAIL": "1"}))
        self.assertEqual(rc, 1)
        [(ran, _, _, _)] = self.calls()
        self.assertTrue(os.path.isdir(ran))
        self.assertIn(f"kept the disposable copy: {os.path.dirname(ran)}", err)

    def test_an_unusable_identifier_is_refused_before_anything_runs(self):
        for bad in ("", "no-dots", "com.tako core.x"):
            with self.subTest(identifier=bad):
                app = self.app("placeholder." + str(abs(hash(bad))))
                with open(os.path.join(app, "Contents/Info.plist"), "wb") as f:
                    plistlib.dump({"CFBundleIdentifier": bad, "CFBundleExecutable": "Tako"}, f)
                rc, _, err = self.finish(self.start(app))
                self.assertEqual(rc, 1)
                self.assertIn("nothing was launched", err)
        self.assertEqual(self.calls(), [])

    def test_concurrent_runs_keep_distinct_logs(self):
        app = self.app("com.tako-core.terminal.e2e")
        first, second = self.start(app), self.start(app, "--scroll-only")
        results = [self.finish(first), self.finish(second)]
        self.assertEqual([rc for rc, _, _ in results], [0, 0], results)
        logs = sorted(name for name in os.listdir(os.path.join(self.root, "target"))
                      if name.startswith("selftest-macapp-log."))
        self.assertEqual(len(logs), 2)
        texts = []
        for name in logs:
            with open(os.path.join(self.root, "target", name)) as f:
                texts.append(f.read())
        self.assertEqual(sorted(text.count("[result]") for text in texts), [1, 4])

    def test_a_failed_tee_cannot_pass(self):
        app = self.app("com.tako-core.terminal.e2e")
        bin_dir = os.path.join(self.root, "fakebin")
        os.makedirs(bin_dir)
        with open(os.path.join(bin_dir, "tee"), "w") as f:
            f.write("#!/bin/sh\ncat > /dev/null\nexit 1\n")
        os.chmod(os.path.join(bin_dir, "tee"), 0o755)
        rc, out, err = self.finish(self.start(app, "--scroll-only", env={"PATH": bin_dir + ":" + os.environ["PATH"]}))
        self.assertEqual(rc, 1)
        self.assertIn("tee status 1", err)
        self.assertNotIn("macapp self-test: ok", out)


if __name__ == "__main__":
    unittest.main()
