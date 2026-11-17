#!/usr/bin/env python3
# tako — Concise CI console over a complete raw log
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Runs one command, keeps every byte it prints in a raw log, and shows only
what a person needs while it runs: start and end, a sparse heartbeat,
completed test and build summaries, and actionable failures.

    python3 scripts/ci_log.py --log target/ci-logs/NAME.log [--label NAME] -- cmd args...

The raw log is the evidence: completion checks and parsers read it, never the
console. The exit status is the command's own (128+N when a signal ended it);
if the wrapper itself fails, it exits non-zero and never reports a pass.
TAKO_CI_VERBOSE=1 shows every line live as before.

check_run.py uses `run_logged` the same way and gets the complete output back.
"""
import os
import re
import selectors
import subprocess
import sys
import time

MAX_LINE = 300            # console characters per line; the raw log keeps all
MAX_SHOWN = 200           # console lines per command before the rest are only counted
MAX_ERRORS = 40           # error lines shown per command
FAILURE_TAIL = 40         # raw lines repeated on the console when the command fails
HEARTBEAT_SECONDS = 60.0  # longest console silence while the command runs

# Completed summaries and stage markers worth a line each.
SUMMARY = re.compile(
    r"^== |"
    r"\*\* (BUILD|TEST|TEST BUILD|TEST EXECUTE|ARCHIVE) (SUCCEEDED|FAILED|INTERRUPTED) \*\*|"
    r"Test Suite '(All tests|Selected tests)' (passed|failed)|"
    r"^\s*Executed \d+ tests?, with|"
    r"Test run with \d+ tests?|"
    r"^test result: |"
    r"^Ran \d+ tests? in |^OK( |$)|^FAILED \(|"
    r"^tako e2e: |^macapp self-test: |^prebuilt: |^built |"
    r"\[simtest\] \d+/\d+ scenarios|Completed \d+ tests? with \d+ failures?|"
    r"^passed=\d+ failed=\d+|^ok +\d|^shard \d+/\d+: all \d+ assigned scenarios finished|"
    r"^COMPILED ONLY|^Run evidence: "
)
# The total after an aggregate XCTest suite; nested suites print the same line.
AGGREGATE = re.compile(r"Test Suite '(All tests|Selected tests)' (passed|failed)")
EXECUTED = re.compile(r"^\s*Executed \d+ tests?, with")
# Failures a person must act on: a located diagnostic, a failed test or
# issue, a crash. Shown (each distinct line once, up to MAX_ERRORS).
FAILURE = re.compile(
    r"^\S[^:]*:\d+(:\d+)?: (fatal )?error: |^(fatal )?error(\[\w+\])?: |"
    r"^Test Case .* failed \(|^✘ Test (?!run with).*(recorded an issue|failed)|"
    r"^FAIL\b|^not ok\b|^--- FAIL|panicked at|Traceback \(most recent call last\)|"
    r"^Fatal error: |\b(Segmentation fault|Abort trap|Killed: 9|Illegal instruction)\b|"
    r"^\[swift watchdog\]|^\[[\w-]+\] FAIL"
)
# Lines that only mention a failure word (logged NSErrors, XCUI activity,
# names like "count-error"): counted, kept in the raw log, never shown.
MENTION = re.compile(r"\berror\b|\bfail(ed|ure)?\b", re.IGNORECASE)
# Compiler-style warnings (and their repeats); counted, never shown.
WARNING = re.compile(r"\bwarning:", re.IGNORECASE)
# A diagnostic's source excerpt and caret: Swift's "331 | code" style or an
# indented continuation right after the diagnostic.
EXCERPT = re.compile(r"^\s*(\d+\s*)?\|")


def failure_key(line):
    """One shown line per failing place: the same assertion recording an
    issue on every frame of a sampled run differs only in its values."""
    m = re.search(r"^✘ Test (\S+) recorded an issue at (\S+?:\d+)", line)
    if m:
        return m.groups()
    m = re.search(r"^(\S[^:]*:\d+): error: (-\[[^\]]+\])", line)
    if m:
        return m.groups()
    return line.strip()


class Console:
    """Decides which raw lines reach the console, and counts the rest."""

    def __init__(self, label, out, verbose=False):
        self.label, self.out, self.verbose = label, out, verbose
        self.lines = self.shown = self.errors = self.errors_shown = self.warnings = 0
        self.after_aggregate = self.in_diagnostic = False
        self.mentions = 0      # lines that only mention error/fail, not shown
        self.seen = set()      # failure lines already shown
        self.last_print = time.monotonic()

    def emit(self, text):
        self.out.write(text + "\n")
        self.out.flush()
        self.last_print = time.monotonic()

    @staticmethod
    def clip(text):
        text = text.rstrip("\r\n")
        if len(text) <= MAX_LINE:
            return text
        return text[:MAX_LINE] + f" … (+{len(text) - MAX_LINE} chars, see raw log)"

    def feed(self, raw):
        self.lines += 1
        line = raw.decode("utf-8", "replace")
        if self.verbose:
            self.out.write(line if line.endswith("\n") else line + "\n")
            self.out.flush()
            self.last_print = time.monotonic()
            return
        after_aggregate, self.after_aggregate = self.after_aggregate, bool(AGGREGATE.search(line))
        # Indented lines right after a diagnostic are its source excerpt and
        # caret: part of that warning or error, kept in the raw log only.
        in_diagnostic, self.in_diagnostic = self.in_diagnostic, False
        if EXECUTED.search(line):
            if not after_aggregate:
                return
        elif EXCERPT.search(line) or (in_diagnostic and line[:1] in (" ", "\t")):
            self.in_diagnostic = in_diagnostic
            return
        elif SUMMARY.search(line) or AGGREGATE.search(line):
            pass
        elif WARNING.search(line):
            self.warnings += 1
            self.in_diagnostic = True
            return
        elif FAILURE.search(line):
            self.in_diagnostic = True
            self.errors += 1
            key = failure_key(line)
            if key in self.seen or self.errors_shown >= MAX_ERRORS:
                return
            self.seen.add(key)
            self.errors_shown += 1
        else:
            if MENTION.search(line):
                self.mentions += 1
            return
        if self.shown >= MAX_SHOWN:
            return
        self.shown += 1
        self.emit(self.clip(line))

    def heartbeat(self, started, raw_path):
        elapsed = int(time.monotonic() - started)
        self.emit(f"[{self.label}] still running {elapsed // 60}m{elapsed % 60:02d}s: "
                  f"{self.lines} lines, {self.errors} failure lines, {self.warnings} warnings (raw: {raw_path})")


def run_logged(cmd, raw_path, label=None, cwd=None, env=None, out=None,
               verbose=None, heartbeat=HEARTBEAT_SECONDS):
    """Runs `cmd` with its stdout and stderr in `raw_path` byte for byte.
    Returns (seconds, exit code, complete output as text)."""
    out = out or sys.stdout
    label = label or os.path.basename(str(cmd[0]))
    if verbose is None:
        verbose = os.environ.get("TAKO_CI_VERBOSE") == "1"
    parent = os.path.dirname(raw_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    console = Console(label, out, verbose)
    started = time.monotonic()
    chunks = []
    with open(raw_path, "wb") as raw:
        # One console line, however long or multi-line the arguments are.
        console.emit(Console.clip(f"[{label}] start: " + " ".join(" ".join(map(str, cmd)).split())))
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            selector = selectors.DefaultSelector()
            selector.register(proc.stdout, selectors.EVENT_READ)
            pending = b""
            while True:
                if not selector.select(timeout=min(heartbeat, 5.0)):
                    if time.monotonic() - console.last_print >= heartbeat:
                        console.heartbeat(started, raw_path)
                    continue
                data = os.read(proc.stdout.fileno(), 65536)
                if not data:
                    break
                raw.write(data)
                raw.flush()
                chunks.append(data)
                pending += data
                *complete, pending = pending.split(b"\n")
                for line in complete:
                    console.feed(line + b"\n")
                if time.monotonic() - console.last_print >= heartbeat:
                    console.heartbeat(started, raw_path)
            if pending:
                console.feed(pending)
            selector.close()
            code = proc.wait()
        except BaseException:
            # The wrapper failed: never leave the command running unobserved.
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            raise
    if code < 0:
        code = 128 - code
    seconds = time.monotonic() - started
    text = b"".join(chunks).decode("utf-8", "replace")
    if code != 0 and not verbose:
        tail = text.splitlines()[-FAILURE_TAIL:]
        console.emit(f"[{label}] last {len(tail)} lines of {raw_path}:")
        for line in tail:
            console.emit("  " + Console.clip(line))
    hidden = console.errors - console.errors_shown
    more = f" ({hidden} repeated or over the limit, in the raw log)" if hidden else ""
    console.emit(f"[{label}] {'ok' if code == 0 else f'FAILED (exit {code})'} in {seconds:.1f}s: "
                 f"{console.lines} lines, {console.errors} failure lines{more}, {console.warnings} warnings, "
                 f"{console.mentions} other error/fail mentions; raw log: {raw_path}")
    return seconds, code, text


def main(argv):
    if "--" not in argv:
        print("usage: ci_log.py --log PATH [--label NAME] -- command...", file=sys.stderr)
        return 2
    split = argv.index("--")
    opts, cmd = argv[:split], argv[split + 1:]
    if not cmd:
        print("ci_log.py: no command", file=sys.stderr)
        return 2
    values = dict(zip(opts[::2], opts[1::2]))
    if "--log" not in values or len(opts) % 2:
        print("usage: ci_log.py --log PATH [--label NAME] -- command...", file=sys.stderr)
        return 2
    try:
        _, code, _ = run_logged(cmd, values["--log"], label=values.get("--label"))
    except Exception as error:  # the wrapper failed; the command's result is unknown
        print(f"FAIL: ci_log.py could not run or log {cmd[0]}: {type(error).__name__}: {error}", file=sys.stderr)
        return 70
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
