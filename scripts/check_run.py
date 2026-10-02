#!/usr/bin/env python3
"""Targeted checks on the test Mac: only the tests a change touches.

Run through scripts/check.sh, which sends it to the test Mac. Each argument
names one check:

    rust:<name>      cargo test --test <name> if tests/<name>.rs exists,
                     else cargo test <name> as a filter
    swift:<filter>   the Swift package's tests matching <filter>, no coverage
    e2e:<a,b,...>    those scenarios of scripts/e2e-macapp.sh on a fresh build
    selftest         the app's self-test on a fresh build
    ios              the iOS terminal surface tests on the simulator

This is not the full CI (scripts/ci.sh): no clippy, no coverage gates, no
iOS scenarios unless asked. The report says exactly what ran. A check that
ran no tests fails -- a misspelt filter must not pass as a green run.

Each check reports build time, GUI-lock wait and run time separately.
"""
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

SWIFT_FLAGS = ["--no-parallel", "-Xlinker", "-L../target/macos", "-Xlinker", "-ltako_core",
               "-Xcc", "-I../target/bindings"]

report = []
failed = False


def run(cmd, cwd=None, env=None):
    """Runs `cmd`, echoing its output; returns (seconds, exit code, output)."""
    started = time.monotonic()
    proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, errors="replace")
    out = []
    for line in proc.stdout:
        sys.stdout.write(line)
        out.append(line)
    proc.wait()
    return time.monotonic() - started, proc.returncode, "".join(out)


def note(check, ok, detail, build=None, lock=None, run_s=None):
    global failed
    failed |= not ok
    report.append((check, ok, detail, build, lock, run_s))


def check_rust(name):
    target = ["--test", name] if os.path.exists(f"tests/{name}.rs") else [name]
    only = target if target[0] == "--test" else []
    build, code, _ = run(["cargo", "test", "--features", "pty,ssh", "--no-run"] + only)
    if code != 0:
        return note(f"rust:{name}", False, "build failed", build)
    secs, code, out = run(["cargo", "test", "--features", "pty,ssh"] + target)
    passed = sum(int(n) for n in re.findall(r"test result: ok\. (\d+) passed", out))
    ok = code == 0 and passed > 0
    note(f"rust:{name}", ok, f"{passed} passed" if passed else "no tests ran", build, None, secs)


def host_framework():
    """The macOS slice the Swift package links, rebuilt only when the engine changed."""
    def stale(artifact):
        # By content, not timestamps: see scripts/engine_fingerprint.py.
        # The build scripts themselves make cargo see changed content.
        return subprocess.run(["python3", "scripts/engine_fingerprint.py", "check", artifact]).returncode != 0

    secs = 0.0
    if stale("TakoCore.xcframework"):
        secs, code, _ = run(["scripts/build-xcframework.sh", "--macos-only"])
        if code != 0:
            return None
    if stale("target/macos/libtako_core.a"):
        s, code, _ = run(["scripts/build-macos-testlib.sh"])
        secs += s
        if code != 0:
            return None
    return secs


def check_swift(filter_):
    prep = host_framework()
    if prep is None:
        return note(f"swift:{filter_}", False, "engine build failed")
    build, code, _ = run(["swift", "build", "--build-tests"] + SWIFT_FLAGS[1:], cwd="swift")
    if code != 0:
        return note(f"swift:{filter_}", False, "build failed", prep + build)
    secs, code, out = run(["swift", "test", "--skip-build"] + SWIFT_FLAGS + ["--filter", filter_], cwd="swift")
    count, finished = swift_test_count(out)
    ok = code == 0 and finished and count > 0
    note(f"swift:{filter_}", ok, f"{count} tests" if count else "no tests ran", prep + build, None, secs)


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


def app_build():
    secs, code, _ = run(["python3", "scripts/build-macapp.py"])
    return secs if code == 0 else None


def lock_wait(out):
    m = re.search(r"\[lock\] tako-gui\.lock waited (\d+)s", out)
    return float(m.group(1)) if m else None


def compile_time(out):
    m = re.search(r"\[timing\] e2e runner compiled in (\d+)s", out)
    return float(m.group(1)) if m else 0.0


def check_e2e(names):
    build = app_build()
    if build is None:
        return note(f"e2e:{names}", False, "app build failed")
    secs, code, out = run(["scripts/e2e-macapp.sh"] + names.split(","))
    ran = len(re.findall(r"^(ok|FAIL)\s", out, re.M))
    ok = code == 0 and ran == len(names.split(","))
    wait = lock_wait(out)
    runner = compile_time(out)
    note(f"e2e:{names}", ok, f"{ran} scenarios" if ran else "no scenarios ran", build + runner, wait,
         secs - (wait or 0) - runner)


def check_selftest():
    build = app_build()
    if build is None:
        return note("selftest", False, "app build failed")
    secs, code, out = run(["scripts/selftest-macapp.sh"])
    wait = lock_wait(out)
    note("selftest", code == 0, "ok" if code == 0 else "failed", build, wait, secs - (wait or 0))


def check_ios():
    secs, code, out = run(["scripts/test-ios-surface.sh"])
    m = re.findall(r"Executed (\d+) tests?, with .*?(\d+) failures", out)
    count = int(m[-1][0]) if m else 0
    # test-ios-surface.sh builds, installs and tests in one go; its phases
    # are not reported separately, so the time is shown as one figure.
    note("ios", code == 0 and count > 0,
         (f"{count} tests" if count else "no tests ran") + "; build+run not separated", None, None, secs)


def fmt(v):
    return "-" if v is None else f"{v:.0f}s"


def main(args):
    if not args:
        print(__doc__)
        return 2
    for arg in args:
        kind, _, value = arg.partition(":")
        if kind == "rust" and value:
            check_rust(value)
        elif kind == "swift" and value:
            check_swift(value)
        elif kind == "e2e" and value:
            check_e2e(value)
        elif arg == "selftest":
            check_selftest()
        elif arg == "ios":
            check_ios()
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
