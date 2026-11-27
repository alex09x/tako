#!/usr/bin/env python3
# tako — the tako-core release Tako builds against
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Where the pinned tako-core release is, for the builders that drive swiftc.

swift/Package.swift names tako-core at one exact version, and
swift/Package.resolved records the commit it resolves to. This resolves the
package exactly as recorded (SwiftPM downloads TakoCore.xcframework.zip and
checks its checksum) and prints, as JSON, the paths a direct build needs:

    python3 scripts/tako_core.py           # resolve, then print the paths
    python3 scripts/tako_core.py --field xcframework

The checkout supplies TakoCoreUI's sources and its Metal shader; the
framework supplies the engine's static library and C headers per platform.
"""
import argparse
import glob
import json
import os
import plistlib
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(ROOT, "swift")
RESOLVED = os.path.join(PACKAGE, "Package.resolved")
IDENTITY = "tako-core"


class Unresolved(Exception):
    pass


def pin(resolved=RESOLVED):
    """The version and commit Package.resolved records for tako-core."""
    with open(resolved) as f:
        data = json.load(f)
    for p in data.get("pins", []):
        if p.get("identity") == IDENTITY:
            return p["state"]["version"], p["state"]["revision"]
    raise Unresolved(f"{resolved} has no {IDENTITY} pin")


def resolve(package=PACKAGE):
    """Fetch the package graph exactly as Package.resolved records it."""
    r = subprocess.run(["swift", "package", "--package-path", package,
                        "--force-resolved-versions", "resolve"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise Unresolved(f"swift package resolve failed:\n{r.stdout}{r.stderr}")


def slices(xcframework):
    """Library and headers of every platform slice, keyed macos-arm64,
    ios-arm64 and ios-arm64-simulator as the framework names them."""
    with open(os.path.join(xcframework, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    out = {}
    for lib in info["AvailableLibraries"]:
        d = os.path.join(xcframework, lib["LibraryIdentifier"])
        out[lib["LibraryIdentifier"]] = {
            "library": os.path.join(d, lib["LibraryPath"]),
            "headers": os.path.join(d, lib.get("HeadersPath", "Headers")),
        }
    return out


def locate(package=PACKAGE, resolved=RESOLVED):
    version, revision = pin(resolved)
    build = os.path.join(package, ".build")
    checkout = os.path.join(build, "checkouts", IDENTITY)
    head = subprocess.run(["git", "-C", checkout, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    if head != revision:
        raise Unresolved(f"{checkout} is at {head or 'nothing'}, Package.resolved says {revision}")
    found = glob.glob(os.path.join(build, "artifacts", IDENTITY, "*", "TakoCore.xcframework"))
    if len(found) != 1:
        raise Unresolved(f"expected one TakoCore.xcframework for {IDENTITY}, found {found}")
    ui = os.path.join(checkout, "swift", "Sources", "TakoCoreUI")
    return {
        "version": version,
        "revision": revision,
        "checkout": checkout,
        "ui_sources": ui,
        "shader": os.path.join(ui, "Resources", "TerminalShaders.metal"),
        "xcframework": found[0],
        "slices": slices(found[0]),
    }


def ui_swift_files(paths):
    """TakoCoreUI's Swift sources in a stable order, its generated binding included."""
    out = []
    for d, _, fs in os.walk(paths["ui_sources"]):
        out += [os.path.join(d, f) for f in sorted(fs) if f.endswith(".swift")]
    return sorted(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--field", help="print one field instead of the whole record")
    parser.add_argument("--no-resolve", action="store_true", help="only locate what is already resolved")
    args = parser.parse_args(argv)
    try:
        if not args.no_resolve:
            resolve()
        paths = locate()
    except Unresolved as e:
        sys.exit(f"tako-core: {e}")
    print(paths[args.field] if args.field else json.dumps(paths, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
