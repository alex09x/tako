#!/usr/bin/env python3
"""Fail when any engine source file's line coverage is below a floor.

    scripts/coverage-gate.py                  # every file under src/, floor 80%
    scripts/coverage-gate.py --min 85 capi.rs # only files whose path ends so
    scripts/coverage-gate.py --features pty pty.rs

Runs `cargo llvm-cov` over the default test targets (needs cargo-llvm-cov and
the llvm-tools rustup component) and prints one line per checked file.
"""

import argparse
import json
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--min", type=float, default=80.0, help="line coverage floor, percent")
parser.add_argument("--features", default="", help="cargo features to enable, e.g. pty,ssh")
parser.add_argument("files", nargs="*", help="path suffixes to check; default: all of src/")
args = parser.parse_args()

cmd = ["cargo", "llvm-cov", "--all-targets", "--json", "--summary-only"]
if args.features:
    cmd += ["--features", args.features]
out = subprocess.run(
    cmd,
    check=True,
    stdout=subprocess.PIPE,
).stdout
report = json.loads(out)

failed = False
checked = 0
for entry in report["data"][0]["files"]:
    name = entry["filename"]
    if "/src/" not in name:
        continue
    rel = name[name.index("/src/") + 1 :]
    if args.files and not any(rel.endswith(f) for f in args.files):
        continue
    lines = entry["summary"]["lines"]
    pct = lines["percent"] if lines["count"] else 100.0
    ok = pct >= args.min
    failed |= not ok
    checked += 1
    print(f"{'ok  ' if ok else 'FAIL'} {pct:6.2f}%  {rel}")

if args.files and checked == 0:
    sys.exit("coverage-gate: no file matched " + ", ".join(args.files))
sys.exit(1 if failed else 0)
