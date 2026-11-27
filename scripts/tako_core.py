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
# The framework slices the direct builders link: the Mac app, the simulator
# app (scripts/build-iosapp.py) and the phone.
REQUIRED_SLICES = ("macos-arm64", "ios-arm64-simulator", "ios-arm64")
# What locate() returns, for --field.
FIELDS = ("version", "revision", "checkout", "ui_sources", "shader", "xcframework", "slices")


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
    libraries = info.get("AvailableLibraries") if isinstance(info, dict) else None
    if not isinstance(libraries, list):
        raise ValueError("Info.plist has no AvailableLibraries list")
    out = {}
    for lib in libraries:
        fields = [lib.get(k, "Headers" if k == "HeadersPath" else None) if isinstance(lib, dict) else None
                  for k in ("LibraryIdentifier", "LibraryPath", "HeadersPath")]
        if not all(isinstance(v, str) and v for v in fields):
            raise ValueError(f"Info.plist has a malformed library entry: {lib!r}")
        ident, library, headers = fields
        d = os.path.join(xcframework, ident)
        out[ident] = {"library": os.path.join(d, library), "headers": os.path.join(d, headers)}
    return out


def same_bytes(a, b):
    with open(a, "rb") as fa, open(b, "rb") as fb:
        return fa.read() == fb.read()


def locate(package=PACKAGE, resolved=RESOLVED):
    version, revision = pin(resolved)
    build = os.path.join(package, ".build")
    checkout = os.path.join(build, "checkouts", IDENTITY)
    head = subprocess.run(["git", "-C", checkout, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    if head != revision:
        raise Unresolved(f"{checkout} is at {head or 'nothing'}, Package.resolved says {revision}")
    # A reused checkout with an edited or added file is refused. (An added
    # file the checkout's ignore rules hide is not seen here, but it is never
    # compiled either: ui_swift_files() takes only files the commit tracks.)
    status = subprocess.run(["git", "-C", checkout, "status", "--porcelain", "--untracked-files=all"],
                            capture_output=True, text=True)
    if status.returncode != 0 or status.stdout.strip():
        changed = status.stdout.strip().splitlines()[:5] or [status.stderr.strip()]
        raise Unresolved(f"{checkout} is not the pinned tree as released: {'; '.join(changed)}")
    found = glob.glob(os.path.join(build, "artifacts", IDENTITY, "*", "TakoCore.xcframework"))
    if len(found) != 1:
        raise Unresolved(f"expected one TakoCore.xcframework for {IDENTITY}, found {found}")
    try:
        framework_slices = slices(found[0])
    except Exception as e:  # any way a damaged Info.plist fails to parse
        raise Unresolved(f"{found[0]} cannot be read ({e!r}); resolve the package again") from e
    missing = [s for s in REQUIRED_SLICES if s not in framework_slices]
    if missing:
        raise Unresolved(f"{found[0]} has no {', '.join(missing)} slice; resolve the package again")
    for name in REQUIRED_SLICES:
        lib, headers = framework_slices[name]["library"], framework_slices[name]["headers"]
        if not os.path.isfile(lib) or not os.path.isdir(headers):
            raise Unresolved(f"{name}: {lib if not os.path.isfile(lib) else headers} is missing; "
                             "resolve the package again")
    ui = os.path.join(checkout, "swift", "Sources", "TakoCoreUI")
    # The framework of this release, not one left from an interrupted
    # resolve: each slice carries the generated binding the checkout has.
    binding = os.path.join(ui, "Generated", "tako_core.swift")
    for name in REQUIRED_SLICES:
        shipped = os.path.join(framework_slices[name]["headers"], "tako_core.swift")
        try:
            same = same_bytes(binding, shipped)
        except OSError as e:
            raise Unresolved(f"{found[0]} ({name}): the binding cannot be read ({e!r}); "
                             "resolve the package again") from e
        if not same:
            raise Unresolved(f"{found[0]} ({name}) is not the framework of {version} ({revision[:12]}): "
                             "its binding differs from the checkout's; resolve the package again")
    return {
        "version": version,
        "revision": revision,
        "checkout": checkout,
        "ui_sources": ui,
        "shader": os.path.join(ui, "Resources", "TerminalShaders.metal"),
        "xcframework": found[0],
        "slices": framework_slices,
    }


def ui_swift_files(paths):
    """TakoCoreUI's Swift sources as the pinned commit has them (its generated
    binding included), in a stable order: files Git tracks there, so nothing
    added to the checkout -- even an ignored file -- is ever compiled."""
    rel = os.path.relpath(paths["ui_sources"], paths["checkout"])
    listed = subprocess.run(["git", "-C", paths["checkout"], "ls-files", "-z", "--", rel],
                            capture_output=True, text=True, check=True).stdout.split("\0")
    return sorted(os.path.join(paths["checkout"], f) for f in listed if f.endswith(".swift"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--field", choices=FIELDS, help="print one field instead of the whole record")
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
