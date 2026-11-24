#!/usr/bin/env python3
# tako — Split the native e2e scenarios over several machines, every one accounted for
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Deterministic shards of the native e2e registry.

The registry is what the runner itself lists (`target/tako-e2e --list`:
one `default NAME` or `explicit NAME` line per scenario). Default scenarios
are dealt longest first onto the least loaded shard, by the durations in
scripts/e2e/durations.json (a scenario without one counts as their median);
explicit-only ones (the persistence cases, kitty) are never sharded here and
are listed as such, so nothing disappears unnoticed.

    python3 scripts/e2e_shards.py plan   --list LIST --shards N
    python3 scripts/e2e_shards.py assign --list LIST --shard I/N     # names, one per line
    python3 scripts/e2e_shards.py check  --list LIST --shard I/N --log LOG
        exit 1 unless every assigned scenario finished exactly once with
        `[result] NAME ok` and nothing else ran
"""

import argparse
import json
import os
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DURATIONS = os.path.join(HERE, "e2e", "durations.json")


class ShardError(Exception):
    pass


def parse_list(text: str) -> tuple[list[str], list[str]]:
    """The runner's registry: default and explicit-only names, in order."""
    default, explicit, seen = [], [], set()
    for line in text.splitlines():
        if not line.strip():
            continue
        m = re.fullmatch(r"(default|explicit) ([a-z0-9][a-z0-9-]*)", line.strip())
        if not m:
            raise ShardError(f"not a registry line: {line!r}")
        kind, name = m.groups()
        if name in seen:
            raise ShardError(f"{name} is listed twice")
        seen.add(name)
        (default if kind == "default" else explicit).append(name)
    if not default:
        raise ShardError("the registry lists no default scenario")
    return default, explicit


def load_durations(path: str = DURATIONS) -> dict[str, float]:
    with open(path) as f:
        return {k: float(v["seconds"]) for k, v in json.load(f)["scenarios"].items()}


def weights(default: list[str], durations: dict[str, float]) -> dict[str, float]:
    """The seconds each default scenario is dealt by: its measured duration,
    or the median of the measured ones when it has none."""
    known = [durations[n] for n in default if n in durations]
    fallback = statistics.median(known) if known else 60.0
    return {n: durations.get(n, fallback) for n in default}


def assign(default: list[str], durations: dict[str, float], shards: int) -> list[list[str]]:
    """Longest first onto the least loaded shard; ties by name and shard
    number, so the same inputs always give the same shards."""
    if shards < 1:
        raise ShardError("at least one shard")
    weight = weights(default, durations)
    loads = [0.0] * shards
    out: list[list[str]] = [[] for _ in range(shards)]
    for name in sorted(default, key=lambda n: (-weight[n], n)):
        i = min(range(shards), key=lambda k: (loads[k], k))
        out[i].append(name)
        loads[i] += weight[name]
    # Each shard runs its scenarios in registry order, as an unsharded run does.
    order = {n: i for i, n in enumerate(default)}
    return [sorted(s, key=order.__getitem__) for s in out]


def account(default: list[str], shards: list[list[str]]) -> None:
    flat = [n for s in shards for n in s]
    if len(flat) != len(set(flat)):
        raise ShardError("a scenario is in two shards")
    if set(flat) != set(default):
        missing, extra = set(default) - set(flat), set(flat) - set(default)
        raise ShardError(f"shards do not cover the registry: missing {sorted(missing)}, extra {sorted(extra)}")


def check_log(assigned: list[str], log: str) -> list[str]:
    """Problems with a shard's run: every assigned scenario must have
    finished exactly once, ok, and nothing else may have run."""
    results: dict[str, list[str]] = {}
    for m in re.finditer(r"^\[result\] ([a-z0-9-]+) (ok|FAIL)\b", log, re.M):
        results.setdefault(m.group(1), []).append(m.group(2))
    problems = []
    for name in assigned:
        got = results.get(name, [])
        if not got:
            problems.append(f"{name}: never finished")
        elif len(got) > 1:
            problems.append(f"{name}: finished {len(got)} times")
        elif got[0] != "ok":
            problems.append(f"{name}: FAIL")
    problems += [f"{name}: ran but was not assigned to this shard" for name in sorted(set(results) - set(assigned))]
    return problems


def shard_arg(text: str) -> tuple[int, int]:
    m = re.fullmatch(r"([1-9][0-9]*)/([1-9][0-9]*)", text)
    if not m or int(m.group(1)) > int(m.group(2)):
        raise ShardError(f"shard must be I/N with 1 <= I <= N, not {text!r}")
    return int(m.group(1)), int(m.group(2))


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="e2e_shards.py")
    p.add_argument("cmd", choices=["plan", "assign", "check"])
    p.add_argument("--list", required=True, help="output of target/tako-e2e --list")
    p.add_argument("--shards", type=int)
    p.add_argument("--shard")
    p.add_argument("--log")
    p.add_argument("--durations", default=DURATIONS)
    a = p.parse_args(argv)
    try:
        # plan takes the shard count; assign and check one shard, I/N, so a
        # mistyped call can never pick (or certify) some shard by default.
        if a.cmd == "plan":
            if a.shards is None or a.shard is not None:
                raise ShardError("plan takes --shards N and no --shard")
            index, total = 0, a.shards
        else:
            if a.shard is None or a.shards is not None:
                raise ShardError(f"{a.cmd} takes --shard I/N and no --shards")
            index, total = shard_arg(a.shard)
        if a.cmd == "check" and not a.log:
            raise ShardError("check needs --log")
        with open(a.list) as f:
            default, explicit = parse_list(f.read())
        durations = load_durations(a.durations)
        shards = assign(default, durations, total)
        account(default, shards)
        if a.cmd == "plan":
            weight = weights(default, durations)
            for i, s in enumerate(shards, 1):
                measured = [n for n in s if n in durations]
                secs = sum(weight[n] for n in s)
                print(f"shard {i}/{total}: {len(s)} scenarios, ~{secs / 60:.1f} min as dealt "
                      f"({len(measured)} measured, {len(s) - len(measured)} at the median)")
            print(f"default {len(default)} = {sum(map(len, shards))} sharded; "
                  f"explicit-only, run elsewhere: {len(explicit)} ({', '.join(explicit)})")
        elif a.cmd == "assign":
            # No names would make the runner run every default scenario.
            if not shards[index - 1]:
                raise ShardError(f"shard {index}/{total} has no scenarios: {len(default)} default ones for {total} shards")
            print("\n".join(shards[index - 1]))
        else:
            with open(a.log) as f:
                problems = check_log(shards[index - 1], f.read())
            for problem in problems:
                print(f"FAIL: shard {index}/{total}: {problem}")
            if problems:
                return 1
            print(f"shard {index}/{total}: all {len(shards[index - 1])} assigned scenarios finished ok")
    except (ShardError, OSError, KeyError, ValueError) as e:
        print(f"FAIL: e2e shards: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
