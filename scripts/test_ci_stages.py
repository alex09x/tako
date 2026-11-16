#!/usr/bin/env python3
# tako — CI stage dispatch: tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""The script scripts/ci.sh actually generates for a stage, run by /bin/bash
(as --local runs it) in a throwaway directory whose scripts/ are stand-ins
that only record how they were called. Nothing is built or launched; the
shard helper is the real one."""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))

STUB_PY = """import os, sys
with open(os.path.join("target", "calls.log"), "a") as f:
    f.write(" ".join([os.path.basename(__file__)] + sys.argv[1:]) + "\\n")
"""
STUBS = {
    "app_locations.py": STUB_PY + 'if sys.argv[1] == "dir": print("target/" + sys.argv[2])\n',
    "prebuilt.py": STUB_PY + 'print("prebuilt: installed stand-in")\n',
    "build-macapp.py": STUB_PY + 'print("built stand-in")\n',
    "selftest-macapp.sh": '#!/bin/bash\necho "selftest-macapp.sh $*" >> target/calls.log\necho "macapp self-test: ok"\n',
    # The runner stand-in: --compile-only leaves a target/tako-e2e that lists
    # REGISTRY; a run prints a full-name result for each scenario it is given,
    # except the one named by STUB_SKIP.
    "e2e-macapp.sh": """#!/bin/bash
echo "e2e-macapp.sh $*" >> target/calls.log
if [ "${1:-}" = --compile-only ]; then
    printf '#!/bin/bash\\n[ "$1" = --list ] && printf "%%s" "$STUB_REGISTRY"\\n' > target/tako-e2e
    chmod +x target/tako-e2e; exit 0
fi
[ $# -gt 0 ] || echo "ok    every-default-scenario"
for n in "$@"; do
    [ "$n" = "${STUB_SKIP:-}" ] && continue
    echo "ok    $n"; echo "[result] $n ok"
done
echo "tako e2e: ok"
""",
}
REGISTRY = "default typing\ndefault split\nexplicit persist-live\ndefault zoom\n"


class CiStageTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = tmp.name
        os.makedirs(os.path.join(self.dir, "scripts", "e2e"))
        os.makedirs(os.path.join(self.dir, "target"))
        for name, body in STUBS.items():
            path = os.path.join(self.dir, "scripts", name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        shutil.copy(os.path.join(HERE, "e2e_shards.py"), os.path.join(self.dir, "scripts"))
        shutil.copy(os.path.join(HERE, "e2e", "durations.json"), os.path.join(self.dir, "scripts", "e2e"))

    def generated(self, stage: str) -> str:
        env = {**os.environ, "TAKO_CI_PRINT_SCRIPT": "1"}
        r = subprocess.run(["bash", os.path.join(HERE, "ci.sh"), "--local", stage], env=env,
                           capture_output=True, text=True, check=True)
        return r.stdout

    def run_stage(self, stage: str, **env):
        r = subprocess.run(["/bin/bash", "-c", self.generated(stage)], cwd=self.dir, capture_output=True, text=True,
                           env={**os.environ, "STUB_REGISTRY": REGISTRY, **env})
        calls_path = os.path.join(self.dir, "target", "calls.log")
        calls = open(calls_path).read().splitlines() if os.path.exists(calls_path) else []
        return r, calls

    def test_the_generated_script_defines_every_helper_it_calls(self):
        script = self.generated("macapp-tests")
        for helper in ("ci_logged", "ci_require", "ci_app_build", "ci_test_stage"):
            self.assertIn(f"{helper} ()", script)

    def test_app_stages_install_the_prebuilt_under_their_own_id(self):
        for stage, bundle in (("macapp-tests", "com.tako-core.terminal.ci"), ("macapp-e2e-tests", "com.tako-core.terminal.e2e")):
            os.remove(os.path.join(self.dir, "target", "calls.log")) if os.path.exists(os.path.join(self.dir, "target", "calls.log")) else None
            r, calls = self.run_stage(stage, TAKO_PREBUILT_DIR="/tmp/pb")
            self.assertEqual(r.returncode, 0, r.stderr)
            installs = [c for c in calls if c.startswith("prebuilt.py install")]
            self.assertEqual(len(installs), 1, calls)
            self.assertIn(f"--bundle-id {bundle} --require-zmx", installs[0])
            self.assertFalse([c for c in calls if c.startswith("build-macapp.py")], calls)

    def test_without_a_prebuilt_the_stage_builds_as_before(self):
        r, calls = self.run_stage("macapp-tests")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue([c for c in calls if c.startswith("build-macapp.py")], calls)
        self.assertFalse([c for c in calls if c.startswith("prebuilt.py")], calls)

    def shard_runs(self, calls):
        return [c for c in calls if c.startswith("e2e-macapp.sh") and "--compile-only" not in c]

    def test_a_shard_runs_exactly_its_assigned_scenarios_and_checks_each(self):
        seen = set()
        for i in (1, 2):
            os.remove(os.path.join(self.dir, "target", "calls.log")) if os.path.exists(os.path.join(self.dir, "target", "calls.log")) else None
            r, calls = self.run_stage("macapp-e2e-shard", TAKO_E2E_SHARD=f"{i}/2")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            runs = self.shard_runs(calls)
            self.assertEqual(len(runs), 1, calls)
            names = runs[0].split()[1:]
            self.assertTrue(names)
            self.assertFalse(seen & set(names))
            seen |= set(names)
            self.assertIn("all", r.stdout)
        self.assertEqual(seen, {"typing", "split", "zoom"})

    def test_a_scenario_that_never_finished_fails_the_shard(self):
        r, _ = self.run_stage("macapp-e2e-shard", TAKO_E2E_SHARD="1/1", STUB_SKIP="split")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("split: never finished", r.stdout + r.stderr)

    def test_an_empty_shard_never_reaches_the_runner(self):
        r, calls = self.run_stage("macapp-e2e-shard", TAKO_E2E_SHARD="4/4")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.shard_runs(calls), [])
        self.assertIn("has no scenarios", r.stderr)

    def test_the_stage_refuses_an_empty_assignment_by_itself(self):
        # As if the helper printed nothing and exited 0: the stage still refuses.
        with open(os.path.join(self.dir, "scripts", "e2e_shards.py"), "w") as f:
            f.write("import sys\nsys.exit(0)\n")
        r, calls = self.run_stage("macapp-e2e-shard", TAKO_E2E_SHARD="1/1")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("FAIL: shard 1/1 has no scenarios", r.stderr)
        self.assertEqual(self.shard_runs(calls), [])

    def test_a_malformed_shard_is_refused_before_anything_runs(self):
        r, calls = self.run_stage("macapp-e2e-shard", TAKO_E2E_SHARD="2")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
