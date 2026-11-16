#!/usr/bin/env python3
# tako — Build the test app once, use it in every test stage
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""One build of Tako.app (with takoctl and zmx) and of the e2e runner, used by
the app, e2e and persistence stages instead of a build each.

    python3 scripts/prebuilt.py pack --app APP --out DIR [--runner target/tako-e2e]
        copy what was built into DIR with a manifest binding it to this
        checkout, its toolchain and SDK, its pins and every file's hash
    python3 scripts/prebuilt.py verify DIR [--require-zmx]
        exit 3 unless DIR was built from exactly this checkout with exactly
        this toolchain and SDK, and no file of it changed
    python3 scripts/prebuilt.py install DIR --app-dir D --bundle-id ID [--require-zmx]
        verify, copy the app to D/Tako.app, reseal it under ID (the
        persistence stage's pattern) and write D/prebuilt-receipt.json; the
        runner, when packed, goes to target/tako-e2e with its inputs key

Nothing is rebuilt or reused silently: any mismatch is a FAIL line naming
it. Without TAKO_PREBUILT_DIR the stages build as they always did.
"""

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = 1
# Inputs a stale bundle could hide behind even at the same commit: the
# toolchain pin, the lockfiles, and the scripts that turn sources into the bundle.
PINS = ["rust-toolchain.toml", "Cargo.lock", "takoctl/Cargo.lock", "scripts/build-macapp.py",
        "scripts/macapp_signing.py", "scripts/build-zmx.sh", "scripts/e2e-macapp.sh"]
# What resealing under another bundle id may change, and nothing else.
RESEALED = {"Contents/Info.plist", "Contents/_CodeSignature/CodeResources", "Contents/MacOS/Tako"}


class Mismatch(Exception):
    pass


def sh(cmd: list[str], cwd: str = ROOT) -> str:
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        raise Mismatch(f"{' '.join(cmd)} failed: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout.strip()


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def tree_hashes(top: str) -> dict[str, str]:
    """Every regular file under `top` by relative path, as hash and mode; a
    link is recorded as its target. A swapped link or a lost executable bit
    (an artifact upload that drops modes) is a change too."""
    out = {}
    for d, dirs, files in os.walk(top):
        dirs.sort()
        for name in sorted(files) + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
            p = os.path.join(d, name)
            rel = os.path.relpath(p, top)
            out[rel] = "link:" + os.readlink(p) if os.path.islink(p) else entry(p)
    return out


def entry(path: str) -> str:
    """A file as hash and ordinary mode bits: a lost executable bit is a change."""
    return f"{sha256(path)}:{os.stat(path).st_mode & 0o777:o}"


def checkout_facts(root: str = ROOT, environ=os.environ) -> dict:
    head = sh(["git", "rev-parse", "HEAD"], root)
    # Untracked but not ignored counts: build-macapp.py compiles every .swift
    # it finds, so a new source file would be built without being in HEAD.
    # Ignored build products (target/) do not.
    dirty = sh(["git", "status", "--porcelain", "--untracked-files=all"], root)
    # The event's SHA and ref are recorded as they are, never rewritten.
    facts = {"head": head, "dirty": bool(dirty),
             "github_sha": environ.get("GITHUB_SHA", ""), "github_ref": environ.get("GITHUB_REF", ""),
             "expected_source_sha": environ.get("TAKO_EXPECTED_SOURCE_SHA", "")}
    expected = facts["expected_source_sha"]
    if expected:
        # A run for an explicit source ref (workflow_dispatch / workflow_call
        # source_ref) checks out another commit than the event's: the
        # workflow resolves that commit and passes it here.
        if not re.fullmatch(r"[0-9a-f]{40}", expected):
            raise Mismatch(f"TAKO_EXPECTED_SOURCE_SHA must be a full commit id, not {expected!r}")
        if expected != head:
            raise Mismatch(f"checkout HEAD {head} is not the expected source {expected}")
    elif facts["github_sha"] and facts["github_sha"] != head:
        # Otherwise the checkout is the event's commit: on a pull request, its merge commit.
        raise Mismatch(f"checkout HEAD {head} is not GITHUB_SHA {facts['github_sha']}")
    return facts


def toolchain_facts(root: str = ROOT) -> dict:
    return {
        "swiftc": sh(["swiftc", "--version"], root).splitlines()[0],
        "xcode": " ".join(sh(["xcodebuild", "-version"], root).split()),
        "macos_sdk": sh(["xcrun", "--sdk", "macosx", "--show-sdk-version"], root),
        "macos_sdk_build": sh(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"], root),
        "rustc": sh(["rustc", "-V"], root),
        "mitts": sh(["mitts", "--version"], root).splitlines()[0],
    }


# The build contract a consumer must share with the producer. The bundle id
# is recorded but not part of it: every stage reseals under its own.
CONTRACT = ("target", "mode", "cargo_features", "codesign")


def info(app: str, key: str) -> str | None:
    try:
        with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
            return plistlib.load(f).get(key)
    except (OSError, plistlib.InvalidFileException):
        return None


def bundle_id(app: str) -> str | None:
    return info(app, "CFBundleIdentifier")


def require_source_stamp(app: str, head: str, what: str) -> None:
    """The commit build-macapp.py stamped into the bundle must be `head`: a
    clean checkout says nothing about a bundle built from another one."""
    stamp = info(app, "TakoSourceCommit")
    if stamp != head:
        raise Mismatch(f"{what}'s TakoSourceCommit is {stamp!r}, not the checkout {head}: "
                       "it was not built from this commit (or from a Git checkout at all)")


def build_facts(app: str, environ=os.environ) -> dict:
    return {"target": "arm64-apple-macos14.0", "mode": "release" if environ.get("RELEASE") == "1" else "debug",
            "cargo_features": "ssh", "with_zmx": os.path.isfile(os.path.join(app, "Contents/Helpers/zmx")),
            "codesign": environ.get("TAKO_CODESIGN_IDENTITY", ""), "bundle_id": bundle_id(app)}


def pin_facts(root: str = ROOT) -> dict:
    return {p: sha256(os.path.join(root, p)) for p in PINS if os.path.exists(os.path.join(root, p))}


def describe(app: str, runner: str | None, root: str, environ) -> dict:
    checkout = checkout_facts(root, environ)
    if checkout["dirty"]:
        raise Mismatch("the checkout has uncommitted changes: its commit does not say what was built")
    return {"schema": SCHEMA, "checkout": checkout, "toolchain": toolchain_facts(root),
            "build": build_facts(app, environ), "pins": pin_facts(root)}


def compare(manifest: dict, current: dict, require_zmx: bool) -> None:
    """Raise Mismatch naming the first difference that makes a prebuilt
    unusable here."""
    if manifest.get("schema") != SCHEMA:
        raise Mismatch(f"manifest schema {manifest.get('schema')} is not {SCHEMA}")
    if manifest["checkout"]["head"] != current["checkout"]["head"]:
        raise Mismatch(f"built from {manifest['checkout']['head']}, this checkout is {current['checkout']['head']}")
    if current["checkout"]["dirty"]:
        raise Mismatch("this checkout has uncommitted changes the prebuilt does not contain")
    for section in ("toolchain", "pins"):
        for key in sorted(set(manifest[section]) | set(current[section])):
            if manifest[section].get(key) != current[section].get(key):
                raise Mismatch(f"{section} {key}: built with {manifest[section].get(key)!r}, "
                               f"here {current[section].get(key)!r}")
    for key in CONTRACT:
        if manifest["build"].get(key) != current["build"].get(key):
            raise Mismatch(f"build {key}: built as {manifest['build'].get(key)!r}, "
                           f"this stage expects {current['build'].get(key)!r}")
    if require_zmx and not manifest["build"]["with_zmx"]:
        raise Mismatch("this stage needs the session runtime, and the prebuilt app has none")


def check_files(recorded: dict[str, str], top: str, what: str) -> None:
    actual = tree_hashes(top)
    missing, extra = sorted(set(recorded) - set(actual)), sorted(set(actual) - set(recorded))
    changed = sorted(k for k in set(recorded) & set(actual) if recorded[k] != actual[k])
    for kind, names in (("missing", missing), ("unexpected", extra), ("changed", changed)):
        if names:
            raise Mismatch(f"{what}: {kind} {', '.join(names[:5])}{' ...' if len(names) > 5 else ''}")


def pack(app: str, out: str, runner: str | None, root: str = ROOT, environ=os.environ) -> dict:
    manifest = describe(app, runner, root, environ)
    if manifest["build"]["codesign"] != "-":
        # Every stage reseals ad hoc under its own id; a shared build signed
        # with a real identity would change meaning when it is resealed.
        raise Mismatch("the shared build must be signed ad hoc (TAKO_CODESIGN_IDENTITY=-)")
    require_source_stamp(app, manifest["checkout"]["head"], "the app")
    os.makedirs(out, exist_ok=False)
    shutil.copytree(app, os.path.join(out, "Tako.app"), symlinks=True)
    manifest["app"] = tree_hashes(os.path.join(out, "Tako.app"))
    if runner:
        shutil.copy2(runner, os.path.join(out, "tako-e2e"))
        shutil.copy2(runner + ".inputs", os.path.join(out, "tako-e2e.inputs"))
        manifest["runner"] = {name: entry(os.path.join(out, name)) for name in ("tako-e2e", "tako-e2e.inputs")}
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    return manifest


def verify(prebuilt: str, require_zmx: bool, root: str = ROOT, environ=os.environ, current: dict | None = None) -> dict:
    with open(os.path.join(prebuilt, "manifest.json")) as f:
        manifest = json.load(f)
    app = os.path.join(prebuilt, "Tako.app")
    compare(manifest, current or describe(app, None, root, environ), require_zmx)
    check_files(manifest["app"], app, "prebuilt app")
    require_source_stamp(app, manifest["checkout"]["head"], "the prebuilt app")
    for name, recorded in manifest.get("runner", {}).items():
        path = os.path.join(prebuilt, name)
        if not os.path.isfile(path) or entry(path) != recorded:
            raise Mismatch(f"prebuilt runner: {name} changed, missing or lost its mode ({recorded})")
    return manifest


def reseal(app: str, bundle_id: str) -> None:
    sh(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {bundle_id}", os.path.join(app, "Contents/Info.plist")])
    # A plain --force --sign - drops the entitlements (Apple Events, audio
    # input, the sounds app group) and the option flags. Keep them; only the
    # identity changes. Requirements are regenerated for the new identifier.
    sh(["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements,flags,runtime", app])


def signing_facts(app: str) -> dict:
    """What the app's signature grants and how it is signed, read back from
    codesign: identifier, option flags, hardened-runtime version, entitlements."""
    ents = sh(["codesign", "-d", "--entitlements", "-", "--xml", app])
    r = subprocess.run(["codesign", "-d", "--verbose=4", app], capture_output=True, text=True)
    if r.returncode != 0:
        raise Mismatch(f"codesign -d {app}: {r.stderr.strip()}")
    facts: dict = {"identifier": None, "flags": [], "runtime": None,
                   "entitlements": plistlib.loads(ents.encode()) if ents.strip() else {}}
    for line in r.stderr.splitlines():
        if line.startswith("Identifier="):
            facts["identifier"] = line.split("=", 1)[1]
        elif line.startswith("CodeDirectory ") and "flags=" in line:
            inner = line.split("flags=", 1)[1].split(" ", 1)[0]
            facts["flags"] = sorted(inner.split("(", 1)[1].rstrip(")").split(",")) if "(" in inner else []
        elif line.startswith("Runtime Version="):
            facts["runtime"] = line.split("=", 1)[1]
    return facts


def require_same_signing(before: dict, after: dict, bundle_id: str) -> None:
    """A reseal changes the identity and nothing the signature grants."""
    if after.get("identifier") != bundle_id:
        raise Mismatch(f"resealed signing identifier is {after.get('identifier')!r}, not {bundle_id}")
    for key in ("entitlements", "flags", "runtime"):
        if before.get(key) != after.get(key):
            raise Mismatch(f"resealing changed the signature's {key}: {before.get(key)!r} -> {after.get(key)!r}")


def install(prebuilt: str, app_dir: str, bundle_id: str, require_zmx: bool, root: str = ROOT,
            environ=os.environ, current: dict | None = None, resealer=reseal, signing=signing_facts) -> dict:
    manifest = verify(prebuilt, require_zmx, root, environ, current)
    app = os.path.join(app_dir, "Tako.app")
    if os.path.exists(app):
        shutil.rmtree(app)
    os.makedirs(app_dir, exist_ok=True)
    shutil.copytree(os.path.join(prebuilt, "Tako.app"), app, symlinks=True)
    signed_before = signing(app)
    resealer(app, bundle_id)
    signed_after = signing(app)
    require_same_signing(signed_before, signed_after, bundle_id)
    after = tree_hashes(app)
    changed = sorted(k for k in set(after) | set(manifest["app"]) if after.get(k) != manifest["app"].get(k))
    if not set(changed) <= RESEALED:
        raise Mismatch(f"resealing changed more than its identity: {', '.join(sorted(set(changed) - RESEALED))}")
    require_source_stamp(app, manifest["checkout"]["head"], "the resealed app")
    if manifest.get("runner"):
        target = os.path.join(root, "target")
        os.makedirs(target, exist_ok=True)
        for name in ("tako-e2e", "tako-e2e.inputs"):
            shutil.copy2(os.path.join(prebuilt, name), os.path.join(target, name))
    with open(os.path.join(prebuilt, "manifest.json"), "rb") as f:
        source = hashlib.sha256(f.read()).hexdigest()
    receipt = {"prebuilt_manifest_sha256": source, "bundle_id": bundle_id, "app": app,
               "resealed": changed, "files": after, "runner_installed": bool(manifest.get("runner")),
               "signing_before": signed_before, "signing_after": signed_after}
    with open(os.path.join(app_dir, "prebuilt-receipt.json"), "w") as f:
        json.dump(receipt, f, indent=2, sort_keys=True)
    return receipt


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="prebuilt.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("pack"); a.add_argument("--app", required=True); a.add_argument("--out", required=True)
    a.add_argument("--runner")
    v = sub.add_parser("verify"); v.add_argument("dir"); v.add_argument("--require-zmx", action="store_true")
    i = sub.add_parser("install"); i.add_argument("dir"); i.add_argument("--app-dir", required=True)
    i.add_argument("--bundle-id", required=True); i.add_argument("--require-zmx", action="store_true")
    args = p.parse_args(argv)
    try:
        if args.cmd == "pack":
            m = pack(args.app, args.out, args.runner)
            print(f"prebuilt: packed {args.out} from {m['checkout']['head']} ({len(m['app'])} app files)")
        elif args.cmd == "verify":
            m = verify(args.dir, args.require_zmx)
            print(f"prebuilt: {args.dir} matches {m['checkout']['head']}")
        else:
            r = install(args.dir, args.app_dir, args.bundle_id, args.require_zmx)
            print(f"prebuilt: installed {r['app']} as {r['bundle_id']} (resealed {', '.join(r['resealed']) or 'nothing'})")
    except (Mismatch, OSError, KeyError, json.JSONDecodeError) as e:
        print(f"FAIL: prebuilt {args.cmd}: {e}; nothing was launched", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
