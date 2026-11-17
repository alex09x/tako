# tako — Motion gate GUI lease and command forwarding
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


class MotionGateCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(Path(__file__).with_name("motion-gate.sh"), scripts / "motion-gate.sh")
        (scripts / "motion-mutants.py").write_text("import sys\nsys.exit(0)\n")
        remote = scripts / "mac-remote.sh"
        remote.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path('command.json').write_text(json.dumps(sys.argv[1:]))
sys.exit(int(os.environ.get('FAKE_REMOTE_STATUS', '0')))
""")
        remote.chmod(0o700)

    def run_gate(self, *args, status=0):
        env = os.environ.copy()
        env.pop("MOTION_MUTANT_RUN", None)
        env["FAKE_REMOTE_STATUS"] = str(status)
        return subprocess.run(["bash", "scripts/motion-gate.sh", *args], cwd=self.root,
                              env=env, capture_output=True, text=True)

    def test_filter_listing_takes_no_gui_lease_or_remote_call(self):
        result = self.run_gate("--filter")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Motion|", result.stdout)
        self.assertFalse((self.root / "command.json").exists())

    def test_the_same_complete_filter_is_forwarded_inside_the_remote_gui_lease(self):
        wanted = self.run_gate("--filter").stdout.strip()
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = json.loads((self.root / "command.json").read_text())
        self.assertEqual(len(commands), 1)
        self.assertEqual(shlex.split(commands[0]),
                         ["python3", "scripts/gui_lock.py", "--", "python3",
                          "scripts/check_run.py", "swift:" + wanted])

    def test_a_failed_remote_gate_remains_a_failed_push(self):
        result = self.run_gate(status=17)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertTrue((self.root / "command.json").exists())


if __name__ == "__main__":
    unittest.main()
