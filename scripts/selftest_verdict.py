#!/usr/bin/env python3
# tako — The macOS app self-test verdict over the e2e runner's own results
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Print `macapp self-test: ok` only when the runner finished with status 0,
said `tako e2e: ok`, and reported exactly one `[result] NAME ok` for every
requested case and no result for any other case.

    python3 scripts/selftest_verdict.py --status RC --log LOG NAME...
"""
import argparse
import re
import sys

RESULT = re.compile(r"^\[result\] (\S+) (ok|FAIL)$", re.M)


def problems(status, text, names):
    found = []
    if status != 0:
        found.append(f"the runner exited with status {status}")
    if not re.search(r"^tako e2e: ok$", text, re.M):
        found.append("the runner did not report `tako e2e: ok`")
    results = RESULT.findall(text)
    for name in names:
        mine = [outcome for case, outcome in results if case == name]
        if not mine:
            found.append(f"no result for {name}")
        elif len(mine) > 1:
            found.append(f"{len(mine)} results for {name}")
        elif mine[0] != "ok":
            found.append(f"{name} failed")
    for case in sorted({case for case, _ in results} - set(names)):
        found.append(f"a result for {case}, which was not requested")
    if not names:
        found.append("no case was requested")
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--status", type=int, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("names", nargs="*")
    args = parser.parse_args(argv)
    try:
        with open(args.log, errors="replace") as f:
            text = f.read()
    except OSError as error:
        found = [f"no runner log: {error}"]
    else:
        found = problems(args.status, text, args.names)
    for problem in found:
        print(f"  FAIL: {problem}", file=sys.stderr)
    if found:
        print("macapp self-test: FAILED", file=sys.stderr)
        return 1
    print("macapp self-test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
