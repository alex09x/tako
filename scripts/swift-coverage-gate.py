#!/usr/bin/env python3
"""Fail when any Swift source file's line coverage is below a floor.

    scripts/swift-coverage-gate.py                         # all of TakoCoreUI, floor 80%
    scripts/swift-coverage-gate.py --min 85 TakoCoreUI/PTYDeliveryPump.swift
    scripts/swift-coverage-gate.py --module TakoKit --module TakoApp/_TakoShim

Runs the whole Swift suite through scripts/swift-test.sh (which rebuilds the
engine when it is stale) with coverage on, and reads SwiftPM's coverage JSON.
Generated bindings are never counted.
"""

import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

parser = argparse.ArgumentParser()
parser.add_argument("--min", type=float, default=80.0, help="line coverage floor, percent")
parser.add_argument("--module", action="append", help="Sources/<dir> to check when no files are named; repeatable (default TakoCoreUI)")
parser.add_argument("files", nargs="*", help="paths relative to swift/Sources to check")
args = parser.parse_args()
modules = args.module or ["TakoCoreUI"]

# A Swift Testing run whose main run loop is stopped by something under test
# ends early with exit status 0, so the exit status alone would pass a run
# that skipped half its tests. Its closing "Test run with N tests" line is
# the proof that it finished.
proc = subprocess.Popen(
    [os.path.join(ROOT, "scripts/swift-test.sh"), "--enable-code-coverage"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
finished = False
for line in proc.stdout:
    sys.stdout.write(line)
    if "Test run with" in line:
        finished = True
if proc.wait() != 0:
    sys.exit(f"swift-coverage-gate: the Swift suite failed (exit {proc.returncode})")
if not finished:
    sys.exit("swift-coverage-gate: the Swift Testing run ended without its summary; it stopped early")
path = subprocess.run(
    ["swift", "test", "--show-codecov-path"],
    cwd=os.path.join(ROOT, "swift"),
    check=True,
    stdout=subprocess.PIPE,
    text=True,
).stdout.strip()

failed = False
checked = 0
for entry in json.load(open(path))["data"][0]["files"]:
    name = entry["filename"]
    if "/Sources/" not in name or "/Generated/" in name:
        continue
    rel = name.split("/Sources/", 1)[1]
    if args.files:
        if rel not in args.files:
            continue
    elif not any(rel.startswith(m + "/") for m in modules):
        continue
    lines = entry["summary"]["lines"]
    pct = lines["percent"] if lines["count"] else 100.0
    ok = pct >= args.min
    failed |= not ok
    checked += 1
    print(f"{'ok  ' if ok else 'FAIL'} {pct:6.2f}%  {rel}")

if checked == 0:
    sys.exit("swift-coverage-gate: nothing matched")
sys.exit(1 if failed else 0)
