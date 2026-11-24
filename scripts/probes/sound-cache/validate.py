#!/usr/bin/env python3
# tako — Validate one sound-cache probe result line against what this run expects.
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
#   validate.py place|remove RESULT_FILE EXIT_STATUS BUNDLE GROUP NAME [SHA256]
# Exit 0 only for a complete, successful, matching result; prints the reason otherwise.
import json, sys


def check(mode, path, status, bundle, group, name, sha=None):
    if status != "0":
        return f"probe exited {status}"
    lines = [l for l in open(path, encoding="utf-8").read().splitlines() if l.strip()]
    if len(lines) != 1:
        return f"expected one JSON line, got {len(lines)}"
    try:
        r = json.loads(lines[0])
    except ValueError:
        return "malformed JSON"
    want = {"mode": mode, "bundle": bundle, "group": group, "name": name, "team": group.split(".", 1)[0]}
    for k, v in want.items():
        if r.get(k) != v:
            return f"{k} is {r.get(k)!r}, expected {v!r}"
    if r.get("groups") != [group]:
        return "entitlement groups are not exactly the probe group"
    expected_file = f"{r.get('container')}/Library/Sounds/tako-{name}.aiff"
    if not r.get("container", "").endswith(f"/Group Containers/{group}") or r.get("file") != expected_file:
        return "container or file path is not the probe group's"
    if mode == "place":
        if r.get("placed") != f"tako-{name}.aiff" or r.get("matchesSystemSound") is not True or not r.get("sha256"):
            return "placement incomplete or bytes differ"
    else:
        if r.get("removed") is not True or (sha and r.get("sha256") != sha):
            return "removal incomplete or not the placed file"
    return None


if __name__ == "__main__":
    why = check(*sys.argv[1:])
    if why:
        print("INVALID:", why); sys.exit(1)
    print("valid")
