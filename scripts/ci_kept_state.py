#!/usr/bin/env python3
# tako — Collect the state a failed native CI case kept, before the VM goes
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Archive exactly the directories this job's failed cases said they kept.

    python3 scripts/ci_kept_state.py --logs target/ci-logs \
        --persist target/e2e-persist-evidence --out target/ci-kept-state

Sources are only this job's own records: `work kept: …[, sessions …]` lines in
the raw stage logs and persistence runner logs, and identity.txt of a
persistence case whose status.txt does not record a clean outcome. Every named
path is validated before it is opened (canonical temporary directory or the
case's own Application Support profile, this user's, exact name); a malformed
descriptor or a refused, missing or unreadable root is recorded, never
skipped silently, and never stops the other roots.

Writes kept-<name>.tar per root and inventory.json. Exit status: 0 complete,
1 partial (a root refused, missing or not fully traversed), 2 error. The
failed test stage stays the job's verdict; this step only adds evidence.
Privacy exclusion and the secret scan are best effort, not a guarantee.
"""
import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tarfile
from pathlib import Path

import ci_kept_walk as walk

WORK_LINE = re.compile(r"^work kept: (.*)$")
NAMES = {"work": re.compile(r"^tkw\.[A-Za-z0-9]{6}$"), "sessions": re.compile(r"^tkd\.[A-Za-z0-9]{6}$"),
         "persist-sessions": re.compile(r"^tkp\.[A-Za-z0-9]{6}$"),
         "support": re.compile(r"^com\.tako-core\.terminal\.e2e-persist-[0-9]+-[0-9]+$")}
PROVIDER_HOMES = ("k",)  # DriverCore: hooks = work/k, CODEX_HOME = work/k/.codex


class Refused(Exception):
    pass


def work_descriptors(path):
    """(source, kind, raw) for every `work kept:` line; a line that does not
    name its paths the expected way is returned with kind None."""
    found = []
    for number, line in enumerate(Path(path).read_text(errors="replace").splitlines(), 1):
        match = WORK_LINE.match(line)
        if not match:
            continue
        source = f"{path}:{number}"
        work, sep, sessions = match.group(1).partition(", sessions ")
        found.append((source, "work", work))
        if sep:
            found.append((source, "sessions", sessions))
        elif ", " in work:
            found[-1] = (source, None, match.group(1))
    return found


def persist_descriptors(evidence):
    """Sessions and support named by a kept persistence case's identity.txt."""
    found = []
    identity = Path(evidence) / "identity.txt"
    fields = dict(line.split(" ", 1) for line in identity.read_text().splitlines() if " " in line)
    outcome = None
    status = Path(evidence) / "status.txt"
    if status.exists():
        outcome = dict(line.split(" ", 1) for line in status.read_text().splitlines() if " " in line).get("outcome")
    if outcome == "0":
        return found  # a clean pass removes its evidence; nothing was kept
    source = str(identity)
    bundle = fields.get("bundle", "")
    found.append((source, "persist-sessions", fields.get("sessions", "")))
    found.append((source, "support", fields.get("support", ""), bundle))
    return found


def validate(kind, raw, tmp_root, tmp_alias, support_root, uid, bundle=None):
    """The canonical path for RAW, or Refused with the reason."""
    if kind not in NAMES:
        raise Refused("malformed descriptor")
    if not raw.startswith("/") or "\x00" in raw:
        raise Refused("not an absolute path")
    path = raw
    if tmp_alias and path.startswith(tmp_alias + "/"):
        path = tmp_root + path[len(tmp_alias):]
    parent = support_root if kind == "support" else tmp_root
    if os.path.dirname(path) != parent:
        raise Refused(f"outside {parent}")
    if not NAMES[kind].match(os.path.basename(path)):
        raise Refused("unexpected name")
    if kind == "support" and os.path.basename(path) != bundle:
        raise Refused("support is not this case's bundle")
    try:
        status = os.lstat(path)
    except FileNotFoundError:
        raise Refused("missing") from None
    if stat.S_ISLNK(status.st_mode):
        raise Refused("root is a symlink")
    if os.path.realpath(path) != path:
        raise Refused("path is not canonical")
    if not stat.S_ISDIR(status.st_mode):
        raise Refused("not a directory")
    if status.st_uid != uid:
        raise Refused("owned by another user")
    return path, status


def collect_root(path, status, out, budget, record):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if not walk.same(status, os.fstat(fd)):
            raise Refused("race: root replaced after validation")
        name = os.path.basename(path)
        tar_path = Path(out) / f"kept-{name}.tar"
        entries, errors = [], []
        # The driver's agent-hook and provider home (TAKO_AGENT_HOOKS_HOME,
        # CODEX_HOME) is work/k: never opened, whatever it holds.
        homes = PROVIDER_HOMES if record.get("kind") == "work" else ()
        with tarfile.open(tar_path, "w", format=tarfile.PAX_FORMAT) as archive:
            walk.archive_root(fd, name, archive, budget, entries, errors, private_homes=homes)
        record.update(decision="collected", tar=tar_path.name,
                      tar_sha256=hashlib.sha256(tar_path.read_bytes()).hexdigest(),
                      entries=entries, errors=errors)
    finally:
        os.close(fd)


def collect(logs, persist, out, *, tmp_root="/private/tmp", tmp_alias="/tmp", home=None, uid=None,
            budget=None):
    """Everything above; returns the inventory dictionary."""
    uid = os.getuid() if uid is None else uid
    home = home or os.path.expanduser("~")
    support_root = os.path.realpath(os.path.join(home, "Library/Application Support"))
    budget = budget or walk.Budget()
    Path(out).mkdir(parents=True, exist_ok=True)
    inventory = {"roots": [], "sources": [], "errors": [], "caps": {
        "entries": budget.entries, "payload_bytes": budget.payload, "file_bytes": budget.file_cap},
        "note": "privacy exclusion and secret scan are best effort; payload cap counts archived bytes"}
    descriptors = []
    log_files = sorted(Path(logs).glob("*.log")) if logs and Path(logs).is_dir() else []
    cases = sorted(p for p in Path(persist).iterdir() if p.is_dir()) if persist and Path(persist).is_dir() else []
    for log in log_files + [case / "runner.log" for case in cases if (case / "runner.log").is_file()]:
        try:
            descriptors += [d + (None,) for d in work_descriptors(log)]
            inventory["sources"].append(str(log))
        except OSError as error:
            inventory["errors"].append({"source": str(log), "error": str(error)})
    for case in cases:
        if not (case / "identity.txt").is_file():
            continue
        try:
            descriptors += [d if len(d) == 4 else d + (None,) for d in persist_descriptors(case)]
            inventory["sources"].append(str(case / "identity.txt"))
        except (OSError, ValueError) as error:
            inventory["errors"].append({"source": str(case), "error": str(error)})
    seen = set()
    for source, kind, raw, bundle in descriptors:
        record = {"source": source, "kind": kind, "named": raw}
        try:
            path, status = validate(kind, raw, tmp_root, tmp_alias, support_root, uid, bundle)
            if path in seen:
                continue
            seen.add(path)
            record["path"] = path
            collect_root(path, status, out, budget, record)
        except Refused as reason:
            record.update(decision="missing" if str(reason) == "missing" else "refused", reason=str(reason))
        except OSError as error:
            record.update(decision="error", reason=f"{type(error).__name__}: {error.strerror}")
        inventory["roots"].append(record)
    roots = inventory["roots"]
    if inventory["errors"] or any(r["decision"] == "error" for r in roots):
        inventory["status"] = "error"
    elif any(r["decision"] != "collected" or r.get("errors") for r in roots):
        inventory["status"] = "partial"
    else:
        inventory["status"] = "complete"
    (Path(out) / "inventory.json").write_text(json.dumps(inventory, indent=2, sort_keys=True))
    return inventory


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--logs")
    parser.add_argument("--persist")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        inventory = collect(args.logs, args.persist, args.out)
    except Exception as error:  # the inventory must say so, not vanish
        Path(args.out).mkdir(parents=True, exist_ok=True)
        (Path(args.out) / "inventory.json").write_text(json.dumps({"status": "error", "error": repr(error)}))
        print(f"kept state: error: {error!r}", file=sys.stderr)
        return 2
    counts = {}
    for root in inventory["roots"]:
        counts[root["decision"]] = counts.get(root["decision"], 0) + 1
    print(f"kept state: {inventory['status']}; roots {counts or 'none named'}; "
          f"source errors {len(inventory['errors'])}; inventory {Path(args.out) / 'inventory.json'}")
    return {"complete": 0, "partial": 1}.get(inventory["status"], 2)


if __name__ == "__main__":
    sys.exit(main())
