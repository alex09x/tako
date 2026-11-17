#!/usr/bin/env python3
# tako — The e2e runner's reuse key: tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""scripts/e2e-macapp.sh --compile-only in a throwaway copy with a stand-in
swiftc that only records its calls: however the script is invoked, the
runner is compiled once and reused; a changed source still recompiles it.
No real compiler, app or screen is involved."""

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))

FAKE_SWIFTC = """#!/bin/bash
if [ "$1" = --version ]; then echo "fake swift 1.0"; exit 0; fi
echo "swiftc $*" >> "$FAKE_LOG"
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
printf 'runner' > "$out"; chmod +x "$out"
"""


class RunnerKeyTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = os.path.realpath(tmp.name)
        os.makedirs(os.path.join(self.dir, "scripts", "e2e"))
        os.makedirs(os.path.join(self.dir, "bin"))
        for name in ("e2e-macapp.sh", "app_locations.py"):
            shutil.copy(os.path.join(HERE, name), os.path.join(self.dir, "scripts", name))
        with open(os.path.join(HERE, "e2e-macapp.sh")) as f:
            # The script may append source groups after its first declaration.
            groups = re.findall(r"^sources(?:\+)?=\((.*)\)$", f.read(), re.M)
            sources = [source for group in groups for source in group.split()]
        self.sources = [s for s in sources if s.startswith("scripts/e2e/")]
        self.assertGreater(len(self.sources), 10)
        for source in self.sources:
            with open(os.path.join(self.dir, source), "w") as f:
                f.write(f"// {source}\n")
        swiftc = os.path.join(self.dir, "bin", "swiftc")
        with open(swiftc, "w") as f:
            f.write(FAKE_SWIFTC)
        os.chmod(swiftc, os.stat(swiftc).st_mode | stat.S_IXUSR)
        self.log = os.path.join(self.dir, "swiftc.log")

    def compile(self, *invocation, cwd=None):
        env = {**os.environ, "PATH": os.path.join(self.dir, "bin") + ":" + os.environ["PATH"], "FAKE_LOG": self.log}
        r = subprocess.run([*invocation, "--compile-only"], cwd=cwd or self.dir, env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stderr

    def compiles(self):
        return len(open(self.log).read().splitlines()) if os.path.exists(self.log) else 0

    def test_every_spelling_of_the_script_reuses_one_runner(self):
        self.assertIn("compiled", self.compile("./scripts/e2e-macapp.sh"))
        self.assertEqual(self.compiles(), 1)
        for invocation, cwd in ((("scripts/e2e-macapp.sh",), None), (("bash", "scripts/e2e-macapp.sh"), None),
                                ((os.path.join(self.dir, "scripts", "e2e-macapp.sh"),), "/")):
            self.assertIn("unchanged", self.compile(*invocation, cwd=cwd), invocation)
        self.assertEqual(self.compiles(), 1, "one compile for all spellings")

    def test_a_changed_source_or_script_still_recompiles(self):
        self.compile("./scripts/e2e-macapp.sh")
        with open(os.path.join(self.dir, self.sources[0]), "a") as f:
            f.write("// changed\n")
        self.assertIn("compiled", self.compile("scripts/e2e-macapp.sh"))
        self.assertEqual(self.compiles(), 2)
        # Also hold the appended group, not just the initial source array.
        with open(os.path.join(self.dir, self.sources[-1]), "a") as f:
            f.write("// appended source changed\n")
        self.assertIn("compiled", self.compile("scripts/e2e-macapp.sh"))
        self.assertEqual(self.compiles(), 3)
        with open(os.path.join(self.dir, "scripts", "e2e-macapp.sh"), "a") as f:
            f.write("\n# flags changed\n")
        self.assertIn("compiled", self.compile("./scripts/e2e-macapp.sh"))
        self.assertEqual(self.compiles(), 4)


if __name__ == "__main__":
    unittest.main()
