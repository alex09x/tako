#!/usr/bin/env python3
# tako — session runtime fetch
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""The session runtime Tako bundles, as a released, checked executable.

The runtime (tako-session) is built and released by tako-core. This script
downloads the release asset for one platform, together with the notices that
must ship with it, checks every file against the SHA-256 pinned in
packaging/session-runtime.json, and prints the path of the executable:

    python3 scripts/session_runtime.py                 # macos-arm64
    python3 scripts/session_runtime.py --platform linux-x86_64
    python3 scripts/session_runtime.py --legacy-fixture

The result is cached under target/session-runtime/, keyed by tag, platform
and hash, so a second call downloads nothing. A cache entry holds the
executable, source.json (what the app's runtime manifest is made from) and
the notices, and is used only when all of them are there and match.

--legacy-fixture fetches the runtime older Tako releases shipped, the same
way: test input for the checks that its sessions still reattach after an
update, never bundled.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIN = os.path.join(ROOT, "packaging", "session-runtime.json")
CACHE = os.path.join(ROOT, "target", "session-runtime")
EXECUTABLE = "tako-session"


class Mismatch(Exception):
    """A downloaded or cached file is not the one pinned."""


def load_pin(path=PIN):
    with open(path) as f:
        return json.load(f)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def asset_url(pin, asset):
    return f"{pin['repository']}/releases/download/{pin['tag']}/{asset}"


def notice_url(pin, path):
    repo = pin["repository"].removeprefix("https://github.com/")
    return f"https://raw.githubusercontent.com/{repo}/{pin['commit']}/{path}"


def curl(url, dest):
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", dest, url], check=True)


def source_record(pin, platform="macos-arm64"):
    """What the app's runtime manifest is made from: the release, the asset
    and that asset's digest as downloaded (`sha256` is added later, over the
    signed file in the bundle, so release checks the asset by this one)."""
    asset = pin["executables"][platform]
    return {"name": pin["name"], "version": pin["version"], "commit": pin["commit"],
            "tag": pin["tag"], "guardedProtocol": pin["guardedProtocol"],
            "asset": asset["asset"], "assetSha256": asset["sha256"]}


def entry_dir(pin, platform, cache=CACHE):
    digest = pin["executables"][platform]["sha256"]
    return os.path.join(cache, f"{pin['tag']}-{platform}-{digest[:16]}")


def files_verified(entry, pin, platform):
    """Whether a cache entry's executable and notices are the pinned files."""
    exe = os.path.join(entry, EXECUTABLE)
    if not (os.path.isfile(exe) and os.access(exe, os.X_OK)):
        return False
    if sha256(exe) != pin["executables"][platform]["sha256"]:
        return False
    for notice in pin["notices"].values():
        p = os.path.join(entry, notice["as"])
        if not os.path.isfile(p) or sha256(p) != notice["sha256"]:
            return False
    return True


def complete(entry, pin, platform):
    """Whether a cache entry holds exactly the pinned files and their record."""
    if not files_verified(entry, pin, platform):
        return False
    try:
        with open(os.path.join(entry, "source.json")) as f:
            return json.load(f) == source_record(pin, platform)
    except (OSError, ValueError):
        return False


def fetch(platform="macos-arm64", pin=None, cache=CACHE, download=curl):
    """The path of the checked executable for `platform`, downloading it once."""
    pin = pin or load_pin()
    if platform not in pin["executables"]:
        raise SystemExit(f"session runtime: no {platform} build in {pin['tag']}")
    entry = entry_dir(pin, platform, cache)
    if complete(entry, pin, platform):
        return os.path.join(entry, EXECUTABLE)
    if files_verified(entry, pin, platform):
        # Every file checks out; only the record is from an older version of
        # this script. Replace it (never writing through whatever is there)
        # rather than download the same files again; if that fails, rebuild.
        temporary = None
        try:
            fd, temporary = tempfile.mkstemp(prefix=".source-", dir=entry)
            with os.fdopen(fd, "w") as f:
                json.dump(source_record(pin, platform), f, sort_keys=True)
            os.replace(temporary, os.path.join(entry, "source.json"))
            if complete(entry, pin, platform):
                return os.path.join(entry, EXECUTABLE)
        except OSError:
            pass
        finally:
            if temporary is not None:
                try:
                    os.remove(temporary)
                except FileNotFoundError:
                    pass
    os.makedirs(cache, exist_ok=True)
    # Assembled aside and renamed into place in one step: an interrupted run
    # never leaves something complete() accepts.
    stage = tempfile.mkdtemp(prefix=".stage-", dir=cache)
    try:
        exe = os.path.join(stage, EXECUTABLE)
        want = pin["executables"][platform]
        download(asset_url(pin, want["asset"]), exe)
        got = sha256(exe)
        if got != want["sha256"]:
            raise Mismatch(f"{want['asset']}: sha256 {got}, pinned {want['sha256']}")
        os.chmod(exe, 0o755)
        for path, notice in pin["notices"].items():
            dest = os.path.join(stage, notice["as"])
            download(notice_url(pin, path), dest)
            got = sha256(dest)
            if got != notice["sha256"]:
                raise Mismatch(f"{path}: sha256 {got}, pinned {notice['sha256']}")
        with open(os.path.join(stage, "source.json"), "w") as f:
            json.dump(source_record(pin, platform), f, sort_keys=True)
        if not complete(stage, pin, platform):
            raise Mismatch("incomplete runtime entry")
        shutil.rmtree(entry, ignore_errors=True)
        os.rename(stage, entry)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return os.path.join(entry, EXECUTABLE)


def fetch_legacy_fixture(pin=None, cache=CACHE, download=curl):
    """The path of the checked legacy runtime fixture, downloading it once."""
    pin = pin or load_pin()
    want = pin["legacyFixture"]
    entry = os.path.join(cache, f"{want['tag']}-legacy-{want['sha256'][:16]}")
    exe = os.path.join(entry, "zmx")
    if os.path.isfile(exe) and os.access(exe, os.X_OK) and sha256(exe) == want["sha256"]:
        return exe
    os.makedirs(cache, exist_ok=True)
    stage = tempfile.mkdtemp(prefix=".stage-", dir=cache)
    try:
        staged = os.path.join(stage, "zmx")
        download(f"{pin['repository']}/releases/download/{want['tag']}/{want['asset']}", staged)
        got = sha256(staged)
        if got != want["sha256"]:
            raise Mismatch(f"{want['asset']}: sha256 {got}, pinned {want['sha256']}")
        os.chmod(staged, 0o755)
        shutil.rmtree(entry, ignore_errors=True)
        os.rename(stage, entry)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return exe


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--platform", default="macos-arm64")
    parser.add_argument("--legacy-fixture", action="store_true",
                        help="the legacy runtime test fixture instead of the runtime")
    args = parser.parse_args(argv)
    try:
        print(fetch_legacy_fixture() if args.legacy_fixture else fetch(args.platform))
    except (Mismatch, subprocess.CalledProcessError) as e:
        sys.exit(f"session runtime: {e}")


if __name__ == "__main__":
    main()
