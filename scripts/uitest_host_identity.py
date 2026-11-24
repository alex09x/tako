#!/usr/bin/env python3
#
# tako — Private UI-test host identity
# Copyright (c) 2026 Alexander Panasenko
#
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# A private UI-test run (scripts/uitest.sh --host-id SUFFIX) builds its host as
# com.tako-core.terminal.uitest.SUFFIX with its own defaults suite. The runner's
# sandbox exceptions name the host literally, so they are generated per run:
#
#   uitest_host_identity.py names SUFFIX
#   uitest_host_identity.py entitlements --template T --suffix S --out F
#   uitest_host_identity.py snapshot --out F
#   uitest_host_identity.py census BUNDLE_ID --out F
#
# The template must be exactly the shared host's entitlements: anything else is
# refused rather than rewritten. No wildcard reaches the shared host, its suite
# or its profile. `snapshot` and `census` only read, and fail closed: an
# inspection that cannot be read is an error (exit 2), never "nothing found".
# `census` exits 3 when the host still has an app or a process in its profile.

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import time

SHARED_HOST = "com.tako-core.terminal.uitest"
SHARED_SUITE = "TAKO_UI_TESTS"
PRIVATE_SUITE_PREFIX = "TAKO_UITEST_RUN_"
SUFFIX = re.compile(r"^[a-z0-9][a-z0-9-]{3,31}$")

SBPL = "com.apple.security.temporary-exception.sbpl"
ABSOLUTE = "com.apple.security.temporary-exception.files.absolute-path.read-write"
HOME_RELATIVE = "com.apple.security.temporary-exception.files.home-relative-path.read-write"
PREFERENCES = "com.apple.security.temporary-exception.shared-preference.read-write"

# ps prints lstart in the C locale only when told to.
TOOL_ENV = {"LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"}
ASN = re.compile(r"ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+")
PID = re.compile(r'^"pid"\s*=\s*(\d+)\s*$', re.M)


class Refused(Exception):
    pass


def socket_hash(host: str) -> str:
    """The prefix of the control socket the host serves: tako-ctl-<hash>.sock."""
    return hashlib.sha256(host.encode()).hexdigest()[:12]


def names(suffix: str) -> tuple[str, str]:
    if not SUFFIX.match(suffix):
        raise Refused(f"host suffix {suffix!r} must match {SUFFIX.pattern}")
    return f"{SHARED_HOST}.{suffix}", PRIVATE_SUITE_PREFIX + suffix


def exceptions(host: str, suite: str) -> dict:
    socket = rf'(allow network-outbound (regex #"^(/private)?/var/folders/[^/]+/[^/]+/T/tako-ctl-{socket_hash(host)}[.]sock$"))'
    return {
        SBPL: [socket],
        ABSOLUTE: ["/private/tmp/tkui/"],
        HOME_RELATIVE: [f"/Library/Application Support/{host}/",
                        f"/Library/Saved Application State/{host}.savedState/"],
        PREFERENCES: [host, suite],
    }


def private_entitlements(template: bytes, suffix: str) -> bytes:
    host, suite = names(suffix)
    if plistlib.loads(template) != exceptions(SHARED_HOST, SHARED_SUITE):
        raise Refused("runner entitlements template is not the expected shared-host template")
    out = plistlib.dumps(exceptions(host, suite), sort_keys=True)
    # Only the private names may remain. The private host id starts with the
    # shared one, so look for the shared literals as whole tokens.
    text = out.decode()
    for shared in (rf"{re.escape(SHARED_HOST)}(?![.\w-])", re.escape(SHARED_HOST) + r"\.savedState",
                   re.escape(socket_hash(SHARED_HOST)), rf"\b{SHARED_SUITE}\b"):
        if re.search(shared, text):
            raise Refused(f"generated entitlements still name the shared host: {shared}")
    return out


def run_tool(argv: list[str], what: str) -> str:
    """A read-only inspection tool's output; any failure is an error that names
    the tool, not its arguments."""
    try:
        done = subprocess.run(argv, capture_output=True, text=True, env=TOOL_ENV, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        raise Refused(f"{what} could not run ({type(error).__name__})")
    if done.returncode != 0:
        raise Refused(f"{what} exited {done.returncode}")
    return done.stdout


def running_pids(bundle_id: str, run=run_tool) -> list[int]:
    """Registered apps with this bundle id. An empty `find` is a real "none"; a
    registered app whose pid cannot be read fails the inspection."""
    found = run(["/usr/bin/lsappinfo", "find", f"bundleid={bundle_id}"], "lsappinfo find")
    asns = ASN.findall(found)
    if found.strip() and not asns:
        raise Refused("lsappinfo find printed no application serial number")
    pids = []
    for asn in asns:
        info = run(["/usr/bin/lsappinfo", "info", "-only", "pid", asn], "lsappinfo info")
        match = PID.findall(info)
        if len(match) != 1:
            raise Refused("lsappinfo info gave no single pid for a registered application")
        pids.append(int(match[0]))
    return sorted(pids)


def process_table(run=run_tool) -> list[list]:
    """Every process: pid, start time and executable path. Malformed rows or a
    table without any process fail the inspection."""
    listing = run(["/bin/ps", "-axww", "-o", "pid=", "-o", "lstart=", "-o", "comm="], "ps")
    rows = []
    for number, line in enumerate(listing.splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split(None, 6)
        try:
            if len(fields) != 7 or not fields[0].isdigit():
                raise ValueError
            started = " ".join(fields[1:6])
            time.strptime(started, "%a %b %d %H:%M:%S %Y")
        except ValueError:
            raise Refused(f"ps row {number} is malformed")
        rows.append([int(fields[0]), started, fields[6]])
    if not rows:
        raise Refused("ps listed no processes")
    return rows


def processes_under(directory: str, run=run_tool) -> list[list]:
    """Processes whose executable lives in `directory` (literally, with its trailing
    slash), such as a host's zmx runtime."""
    prefix = directory.rstrip("/") + "/"
    return sorted(row for row in process_table(run) if row[2].startswith(prefix))


def entry(path: str) -> dict:
    st = os.lstat(path)
    item = {"type": stat.S_IFMT(st.st_mode), "mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid,
            "size": st.st_size, "mtime_ns": st.st_mtime_ns, "ino": st.st_ino, "dev": st.st_dev}
    if stat.S_ISLNK(st.st_mode):
        item["link"] = os.readlink(path)
    elif stat.S_ISREG(st.st_mode):
        with open(path, "rb") as f:
            item["sha256"] = hashlib.sha256(f.read()).hexdigest()
    return item


def describe(path: str) -> dict:
    """`path` itself and everything under it: type, mode, owner, size, time, inode,
    link target and content hash. Links are recorded, never followed; nothing is
    modified. An unreadable directory fails the inspection."""
    if not os.path.lexists(path):
        return {"exists": False}
    entries = {".": entry(path)}
    if stat.S_ISDIR(os.lstat(path).st_mode):
        def unreadable(error):
            raise Refused(f"cannot read part of the profile ({type(error).__name__})")
        for root, dirs, files in os.walk(path, onerror=unreadable):
            for name in sorted(dirs + files):
                full = os.path.join(root, name)
                entries[os.path.relpath(full, path)] = entry(full)
    return {"exists": True, "entries": entries}


def snapshot(home: str, run=run_tool) -> dict:
    library = os.path.join(home, "Library")
    return {
        "host": SHARED_HOST,
        "pids": running_pids(SHARED_HOST, run),
        "processes": processes_under(os.path.join(library, "Application Support", SHARED_HOST), run),
        "profile": {
            rel: describe(os.path.join(library, rel)) for rel in (
                f"Application Support/{SHARED_HOST}",
                f"Saved Application State/{SHARED_HOST}.savedState",
                f"Preferences/{SHARED_HOST}.plist",
                f"Preferences/{SHARED_SUITE}.plist",
            )
        },
    }


def census(bundle_id: str, home: str, run=run_tool) -> dict:
    """A host's registered apps and the processes running from its own profile."""
    support = os.path.join(home, "Library/Application Support", bundle_id)
    return {"host": bundle_id, "apps": running_pids(bundle_id, run), "profile": processes_under(support, run)}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    n = sub.add_parser("names")
    n.add_argument("suffix")
    e = sub.add_parser("entitlements")
    e.add_argument("--template", required=True)
    e.add_argument("--suffix", required=True)
    e.add_argument("--out", required=True)
    s = sub.add_parser("snapshot")
    s.add_argument("--out", required=True)
    c = sub.add_parser("census")
    c.add_argument("bundle_id")
    c.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "names":
            print(*names(args.suffix))
        elif args.command == "entitlements":
            with open(args.template, "rb") as f:
                generated = private_entitlements(f.read(), args.suffix)
            with open(args.out, "wb") as f:
                f.write(generated)
        elif args.command == "snapshot":
            taken = snapshot(os.path.expanduser("~"))
            with open(args.out, "w") as f:
                json.dump(taken, f, indent=1, sort_keys=True)
        else:
            found = census(args.bundle_id, os.path.expanduser("~"))
            with open(args.out, "w") as f:
                json.dump(found, f, indent=1, sort_keys=True)
            print(json.dumps(found))
            if found["apps"] or found["profile"]:
                return 3
    except Refused as error:
        print(f"uitest host identity: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
