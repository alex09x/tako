#!/usr/bin/env python3
# tako — Where test apps are built and run from
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Keep the apps the tests launch off external volumes.

macOS asks once per app before an app reads or writes an external volume.
Test apps are rebuilt under new identities, so from a checkout on such a
volume -- the test Mac builds on one -- every run asked again, by hand. A
checkout on the startup disk keeps today's paths; a checkout on an
external volume gets its test apps under the startup disk's caches.

    python3 scripts/app_locations.py dir NAME     # print where test app NAME goes
    python3 scripts/app_locations.py check-app PATH
        # refuse (exit 3) if the app at PATH would run from an external volume
    python3 scripts/app_locations.py check-source ROUTE
        # refuse (exit 3) if this checkout is on an external volume: ROUTE runs
        # tests that read files of the source tree at run time (#filePath)

TAKO_E2E_APP_ROOT replaces the cache root for relocated apps.
"""

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTERNAL = "/Volumes/"


def is_external(path: str) -> bool:
    """True when `path`, or the nearest of its parents that exists, resolves
    onto an external volume."""
    probe = os.path.abspath(path)
    while not os.path.exists(probe) and probe != os.path.dirname(probe):
        probe = os.path.dirname(probe)
    return os.path.realpath(probe).startswith(EXTERNAL)


def app_dir(name: str, root: str | None = None, environ=os.environ) -> str:
    """Where test app `name` is built and run from: target/NAME in a checkout
    on the startup disk, otherwise one directory per checkout under the
    startup disk's caches."""
    root = root or ROOT
    if not is_external(root):
        return os.path.join("target", name)
    base = environ.get("TAKO_E2E_APP_ROOT") or os.path.join(os.path.expanduser("~"), "Library/Caches/tako-e2e")
    key = hashlib.sha256(os.path.realpath(root).encode()).hexdigest()[:12]
    return os.path.join(base, key, name)


def check_app(path: str) -> str | None:
    """Why the app at `path` must not be launched, or None."""
    if is_external(path):
        return (f"FAIL: the test app {path} would run from an external volume, where macOS asks for "
                "access on every new build; build it with scripts/app_locations.py's directory instead")
    return None


def check_source(route: str, root: str | None = None) -> str | None:
    """Why `route` must not run from this checkout, or None."""
    root = root or ROOT
    if is_external(root):
        return (f"FAIL: {route} runs tests that read the source tree while they run, and this checkout is on "
                f"an external volume ({os.path.realpath(root)}), where macOS would ask for access. "
                "Run it from a checkout on the startup disk, e.g. "
                "TAKO_MAC_DIR=/private/tmp/tako-<name> scripts/mac-remote.sh ...; nothing was launched")
    return None


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "dir":
        print(app_dir(argv[1]))
        return 0
    if len(argv) == 2 and argv[0] in ("check-app", "check-source"):
        reason = check_app(argv[1]) if argv[0] == "check-app" else check_source(argv[1])
        if reason:
            print(reason, file=sys.stderr)
            return 3
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
