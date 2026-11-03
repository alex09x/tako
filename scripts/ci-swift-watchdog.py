#!/usr/bin/env python3
# tako — Diagnose a Swift test runner that stops making progress
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import argparse
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import time


def descendants(root):
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,stat=,%cpu=,rss=,comm="],
        capture_output=True, text=True, timeout=5)
    rows = [line.split(None, 6) for line in result.stdout.splitlines()]
    rows = [row for row in rows if len(row) == 7]
    owned = {root}
    # SwiftPM may put a helper in its own process group. The new session still
    # identifies it even if the parent exits before its output pipe closes.
    for row in rows:
        try:
            if os.getsid(int(row[0])) == root:
                owned.add(int(row[0]))
        except OSError:
            pass
    while True:
        expanded = owned | {int(row[0]) for row in rows if int(row[1]) in owned}
        if expanded == owned:
            return [row for row in rows if int(row[0]) in owned]
        owned = expanded


def stop(proc):
    try:
        rows = descendants(proc.pid)
    except (OSError, subprocess.SubprocessError):
        rows = []
    owned = [int(row[0]) for row in rows if int(row[0]) != proc.pid]
    for pid in owned:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    for pid in owned:
        try:
            if os.getsid(pid) == proc.pid:
                os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


def diagnose(proc, directory):
    directory.mkdir(parents=True, exist_ok=True)
    try:
        rows = descendants(proc.pid)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"[swift watchdog] process inspection failed: {error}", flush=True)
        rows = []
    for row in rows:
        # Deliberately log executable names, never command-line arguments/env.
        print("[swift watchdog] " + " ".join(row[:6] + [Path(row[6]).name]), flush=True)
    for tool, arguments in [("vm_stat", []), ("sysctl", ["vm.swapusage"])]:
        executable = shutil.which(tool)
        if executable:
            try:
                result = subprocess.run([executable, *arguments], capture_output=True, text=True, timeout=5)
                print(result.stdout[:5000], flush=True)
            except (OSError, subprocess.SubprocessError) as error:
                print(f"[swift watchdog] {tool} unavailable: {error}", flush=True)
    sampler = shutil.which("sample")
    if sampler:
        for row in rows:
            name = Path(row[6]).name
            if "swiftpm-testing" not in name and "xctest" not in row[6] and not name.endswith("PackageTests"):
                continue
            try:
                result = subprocess.run([sampler, row[0], "3", "1"], capture_output=True, text=True, timeout=10)
                output = result.stdout + result.stderr
                (directory / f"swift-test-{row[0]}.txt").write_text(output)
                print("\n".join(output.splitlines()[:110]), flush=True)
            except (OSError, subprocess.SubprocessError) as error:
                print(f"[swift watchdog] sample unavailable: {error}", flush=True)


def runtime_started(line):
    line = re.sub(rb"\x1b\[[0-9;]*m", b"", line).lstrip()
    return ((line.startswith(b"Test Suite '") and b" started" in line)
            or line.startswith("◇ Test run started".encode()))


def run(command, idle_timeout, directory):
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    pending = bytearray()
    runtime = False
    last_output = time.monotonic()
    received_signal = []

    def relay(number, _frame):
        received_signal.append(number)
        if proc.poll() is None:
            proc.send_signal(number)

    previous = {number: signal.signal(number, relay) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            while True:
                if received_signal:
                    return 128 + received_signal[0]
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fileobj.fileno(), 16384)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    last_output = time.monotonic()
                    pending.extend(chunk)
                    while b"\n" in pending:
                        line, _, rest = pending.partition(b"\n")
                        runtime = runtime or runtime_started(line)
                        pending = bytearray(rest)
                    if len(pending) > 65536:
                        pending = pending[-65536:]
                code = proc.poll()
                if code is not None and not selector.get_map():
                    return 128 - code if code < 0 else code
                # Compilation remains under the existing workflow job budget.
                # Arm only after a real XCTest/Swift Testing runtime starts.
                if runtime and time.monotonic() - last_output >= idle_timeout:
                    print(f"[swift watchdog] no test output for {idle_timeout:g}s; collecting native stacks", flush=True)
                    diagnose(proc, directory)
                    return 124
    finally:
        stop(proc)
        if proc.stdout:
            # Keep diagnostics emitted during sampling/termination without
            # waiting on a daemon that might have inherited the output pipe.
            os.set_blocking(proc.stdout.fileno(), False)
            while True:
                try:
                    chunk = os.read(proc.stdout.fileno(), 16384)
                    if not chunk:
                        break
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                except OSError:
                    break
            proc.stdout.close()
        for number, handler in previous.items():
            signal.signal(number, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--idle-timeout", type=float, default=180)
    parser.add_argument("--diagnostics-dir", type=Path, default=Path("target/ci-logs/swift-stall"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.idle_timeout <= 0:
        parser.error("a command and a positive idle timeout are required")
    return run(command, args.idle_timeout, args.diagnostics_dir)


if __name__ == "__main__":
    sys.exit(main())
