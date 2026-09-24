#!/usr/bin/env python3
"""Fail when any iOS app source file's line coverage is below a floor.

    scripts/ios-coverage-gate.py              # read the last simtest walkthrough
    scripts/ios-coverage-gate.py --run        # run the walkthrough first
    scripts/ios-coverage-gate.py --min 85 Session.swift

Coverage comes from the XCUITest walkthrough that scripts/simtest.py runs in
the simulator with code coverage on (target/simtest/walkthrough.xcresult).
Only files under swift/Sources/iOSApp are checked; TakoCoreUI has its own
gate in scripts/swift-coverage-gate.py.
"""

import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULT = os.path.join(ROOT, "target/simtest/walkthrough.xcresult")

parser = argparse.ArgumentParser()
parser.add_argument("--min", type=float, default=80.0, help="line coverage floor, percent")
parser.add_argument("--run", action="store_true", help="run the simtest walkthrough first")
parser.add_argument("files", nargs="*", help="file names under swift/Sources/iOSApp to check")
args = parser.parse_args()

tests_failed = False
if args.run:
    # Report coverage even when a walkthrough test fails, but still fail.
    tests_failed = subprocess.run(
        ["python3", os.path.join(ROOT, "scripts/simtest.py"), "walkthrough"]
    ).returncode != 0
if not os.path.isdir(RESULT):
    sys.exit(f"ios-coverage-gate: {RESULT} is missing; run scripts/simtest.py walkthrough first")

report = json.loads(subprocess.run(
    ["xcrun", "xccov", "view", "--report", "--json", RESULT],
    check=True, stdout=subprocess.PIPE,
).stdout)

failed = False
checked = 0
for target in report.get("targets", []):
    for f in target.get("files", []):
        path = f.get("path", "")
        if "/swift/Sources/iOSApp/" not in path:
            continue
        name = path.split("/swift/Sources/iOSApp/", 1)[1]
        if args.files and name not in args.files:
            continue
        if f.get("executableLines", 0) == 0:
            continue
        pct = 100.0 * f["lineCoverage"]
        ok = pct >= args.min
        failed |= not ok
        checked += 1
        print(f"{'ok  ' if ok else 'FAIL'} {pct:6.2f}%  iOSApp/{name}")

if checked == 0:
    sys.exit("ios-coverage-gate: no iOSApp files in the coverage report")
if tests_failed:
    print("ios-coverage-gate: the walkthrough itself failed")
sys.exit(1 if failed or tests_failed else 0)
