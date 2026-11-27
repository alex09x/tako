#!/usr/bin/env python3
# tako — Focused application verification
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

"""Targeted checks on the test Mac: only the tests a change touches.

Run through scripts/check.sh, which sends it to the test Mac. Each argument
names one check:

    swift:<filter>   the Swift package's tests matching <filter>, no coverage
    e2e:<a,b,...>    those scenarios of scripts/e2e-macapp.sh on a fresh build
    selftest         the app's self-test on a fresh build
    iosunit:<A,B,..> those hosted unit-test classes of the phone app (ios/UnitTests) on the simulator

The engine and TakoCoreUI are tako-core's, tested there; their release is
pinned in swift/Package.swift.

This is not the full CI (scripts/ci.sh): no clippy, no coverage gates, no
iOS scenarios unless asked. The report says exactly what ran. A check that
ran no tests fails -- a misspelt filter must not pass as a green run.

Each check reports build time, GUI-lock wait and run time separately.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ci_log  # noqa: E402

# The tako-core release exactly as Package.resolved records it.
SWIFT_FLAGS = ["--no-parallel", "--force-resolved-versions"]

report = []
failed = False


CHECK_LOGS = os.path.join("target", "check-logs")
_runs = 0
_run_dir = None


def run_dir():
    """This invocation's own log directory, created exclusively: a reused
    PID or a repeated command never reaches an earlier run's files."""
    global _run_dir
    if _run_dir is None:
        os.makedirs(CHECK_LOGS, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        _run_dir = tempfile.mkdtemp(prefix=f"{stamp}-{os.getpid()}-", dir=CHECK_LOGS)
    return _run_dir


def run(cmd, cwd=None, env=None):
    """Runs `cmd`; returns (seconds, exit code, complete output).

    Every byte goes to its own file in this invocation's directory under
    target/check-logs (never replacing one); the console gets start/end, a
    heartbeat, summaries and failures (scripts/ci_log.py), or everything with
    TAKO_CI_VERBOSE=1. The pass/count parsers read the complete output
    returned here, never the console."""
    global _runs
    _runs += 1
    name = re.sub(r"[^A-Za-z0-9_.-]+", "-", " ".join(os.path.basename(str(c)) for c in cmd[:3])).strip("-")
    path = os.path.join(run_dir(), f"{_runs:02d}-{name[:60]}.log")
    return ci_log.run_logged(cmd, path, label=name[:40], cwd=cwd, env=env, exclusive=True)


def note(check, ok, detail, build=None, lock=None, run_s=None):
    global failed
    failed |= not ok
    report.append((check, ok, detail, build, lock, run_s))


def check_swift(filter_):
    build, code, _ = run(["swift", "build", "--build-tests"] + SWIFT_FLAGS[1:], cwd="swift")
    if code != 0:
        return note(f"swift:{filter_}", False, "build failed", build)
    secs, code, out = run(["swift", "test", "--skip-build"] + SWIFT_FLAGS + ["--filter", filter_], cwd="swift")
    count, finished = swift_test_count(out)
    ok = code == 0 and finished and count > 0
    note(f"swift:{filter_}", ok, f"{count} tests" if count else "no tests ran", build, None, secs)


def swift_test_count(out):
    """Tests run by both frameworks the package uses, and whether each one
    that started also finished.

    Swift Testing: once "Test run started" appears, its closing "Test run
    with N test(s) [in M suite(s)] passed|failed" must too. XCTest: the
    aggregate suite ('Selected tests' for a filtered run, else 'All tests')
    must close, and its total is the "Executed N tests" right after that
    close -- never a nested suite's.
    """
    count = 0
    finished = True
    closes = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)", out)
    if "Test run started" in out or closes:
        if closes:
            count += int(closes[-1][0])
            finished &= closes[-1][1] == "passed"
        else:
            finished = False
    for aggregate in ("Selected tests", "All tests"):
        if f"Test Suite '{aggregate}' started" not in out:
            continue
        m = re.search(rf"Test Suite '{aggregate}' (passed|failed) at [^\n]*\n\s*Executed (\d+) tests?, "
                      r"with (?:\d+ tests? skipped and )?(\d+) failures?", out)
        if m:
            count += int(m.group(2))
            finished &= m.group(1) == "passed" and m.group(3) == "0"
        else:
            finished = False
        break
    return count, finished


# Where the e2e app is built and where scripts/e2e-macapp.sh runs it from:
# one place. Built into target/macapp while the runner took a target/macapp-e2e
# left from an older build, every e2e check drove a stale app. Off any
# external volume (scripts/app_locations.py), where macOS asks on every build.
E2E_APP_DIR = subprocess.run(
    [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "app_locations.py"), "dir", "macapp-e2e"],
    check=True, capture_output=True, text=True).stdout.strip()


def e2e_env():
    env = dict(os.environ)
    env.setdefault("TAKO_BUNDLE_ID", "com.tako-core.terminal.e2e")
    env.setdefault("TAKO_APP_DIR", E2E_APP_DIR)
    return env


def app_build():
    secs, code, _ = run(["python3", "scripts/build-macapp.py"], env=e2e_env())
    return secs if code == 0 else None


def lock_wait(out):
    m = re.search(r"\[lock\] tako-gui\.lock waited (\d+)s", out)
    return float(m.group(1)) if m else None


def compile_time(out):
    m = re.search(r"\[timing\] e2e runner compiled in (\d+)s", out)
    return float(m.group(1)) if m else 0.0


def check_e2e(names):
    scenario_list = [s for s in names.split(",") if s]
    persist_scenarios = [s for s in scenario_list if s.startswith("persist-")]
    normal_scenarios = [s for s in scenario_list if not s.startswith("persist-")]

    total_secs = 0.0
    total_out = ""
    total_code = 0
    total_build = 0.0

    if normal_scenarios:
        build = app_build()
        if build is None:
            return note(f"e2e:{names}", False, "app build failed")
        total_build += build
        secs, code, out = run(["scripts/e2e-macapp.sh"] + normal_scenarios, env=e2e_env())
        total_secs += secs
        total_out += out
        if code != 0:
            total_code = code

    if persist_scenarios:
        secs, code, out = run(["scripts/e2e-persist.sh"] + persist_scenarios)
        total_secs += secs
        total_out += out
        if code != 0:
            total_code = code

    ran = len(re.findall(r"^(ok|FAIL)\s", total_out, re.M))
    ok = total_code == 0 and ran == len(scenario_list)
    wait = lock_wait(total_out)
    runner = compile_time(total_out)
    note(f"e2e:{names}", ok, f"{ran} scenarios" if ran else "no scenarios ran", total_build + runner, wait,
         total_secs - (wait or 0) - runner)


def check_selftest():
    build = app_build()
    if build is None:
        return note("selftest", False, "app build failed")
    secs, code, out = run(["scripts/selftest-macapp.sh"], env=e2e_env())
    wait = lock_wait(out)
    note("selftest", code == 0, "ok" if code == 0 else "failed", build, wait, secs - (wait or 0))


def check_iosunit(classes):
    secs, code, out = run(["scripts/ios-unit-test.sh"] + [c for c in classes.split(",") if c])
    m = re.findall(r"Executed (\d+) tests?, with (\d+) failures", out)
    count = int(m[-1][0]) if m else 0
    note(f"iosunit:{classes}", code == 0 and count > 0 and "TEST SUCCEEDED" in out,
         f"{count} tests" if count else "no tests ran", None, None, secs)


def fmt(v):
    return "-" if v is None else f"{v:.0f}s"


def main(args):
    if not args:
        print(__doc__)
        return 2
    for arg in args:
        kind, _, value = arg.partition(":")
        if kind == "swift" and value:
            check_swift(value)
        elif kind == "e2e" and value:
            check_e2e(value)
        elif arg == "selftest":
            check_selftest()
        elif kind == "iosunit" and value:
            check_iosunit(value)
        else:
            print(f"unknown check: {arg}", file=sys.stderr)
            return 2
    print("\n== targeted checks (not the full CI) ==")
    print(f"{'check':40} {'result':8} {'build':>7} {'lock':>6} {'run':>7}  detail")
    for check, ok, detail, build, lock, run_s in report:
        print(f"{check:40} {'ok' if ok else 'FAILED':8} {fmt(build):>7} {fmt(lock):>6} {fmt(run_s):>7}  {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
