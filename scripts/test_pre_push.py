#!/usr/bin/env python3
# tako — Required push gates run synchronously, without detached mutation work
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).resolve().parent / "git-hooks/pre-push"


class PrePushTests(unittest.TestCase):
    def run_hook(self, changed, motion=0):
        with tempfile.TemporaryDirectory(prefix="tako-hook-") as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            (root / ".git").mkdir()
            (root / "scripts").mkdir()

            def script(path, content):
                path.write_text("#!/bin/bash\nset -eu\n" + content)
                path.chmod(0o755)

            script(root / "bin/git", """case "$1" in
rev-parse)
  if [ "$2" = --git-dir ]; then printf '%s\n' "$HOOK_TEST_ROOT/.git"
  else printf '%s\n' "$HOOK_TEST_ROOT"; fi ;;
diff|log) printf '%s\n' "$HOOK_TEST_CHANGED" ;;
config) printf '%s\n' fixture@test ;;
*) exit 93 ;;
esac
""")
            script(root / "scripts/motion-gate.sh", """echo motion >> "$HOOK_TEST_LOG"
exit "$HOOK_TEST_MOTION"
""")
            script(root / "scripts/check.sh", 'echo "check $*" >> "$HOOK_TEST_LOG"\n')
            script(root / "scripts/motion-mutants.py", 'echo mutant >> "$HOOK_TEST_LOG"\n')
            env = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                       TAKO_MAC="fixture@test", HOOK_TEST_ROOT=str(root),
                       HOOK_TEST_CHANGED=changed, HOOK_TEST_LOG=str(root / "calls"),
                       HOOK_TEST_MOTION=str(motion))
            update = "refs/heads/topic " + "1" * 40 + " refs/heads/topic " + "2" * 40 + "\n"
            result = subprocess.run(["/bin/bash", str(HOOK)], input=update, text=True,
                                    capture_output=True, env=env, cwd=root, timeout=10)
            calls = (root / "calls").read_text().splitlines() if (root / "calls").exists() else []
            return result.returncode, calls, result.stdout + result.stderr

    def test_non_swift_changes_need_no_swift_gate(self):
        self.assertEqual(self.run_hook("README.md")[:2], (0, []))

    def test_moving_swift_changes_run_motion_without_a_detached_campaign(self):
        code, calls, output = self.run_hook("swift/Sources/TakoApp/Features/Sidebar/Row.swift")
        self.assertEqual((code, calls), (0, ["motion"]), output)
        self.assertNotIn("mutants running", output)

    def test_phone_app_changes_run_the_motion_gate_only(self):
        self.assertEqual(self.run_hook("swift/Sources/iOSApp/TerminalScreen.swift")[:2], (0, ["motion"]))

    def test_failed_motion_blocks_the_push(self):
        self.assertEqual(self.run_hook("swift/Sources/TakoApp/Features/Sidebar/Row.swift", motion=7)[:2],
                         (7, ["motion"]))


if __name__ == "__main__":
    unittest.main()
