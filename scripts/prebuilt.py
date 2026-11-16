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
            if os.path.islink(p):
                out[rel] = "link:" + os.readlink(p)
            else:
                out[rel] = f"{sha256(p)}:{os.stat(p).st_mode & 0o777:o}"
    return out


def checkout_facts(root: str = ROOT, environ=os.environ) -> dict:
    head = sh(["git", "rev-parse", "HEAD"], root)
    # Untracked but not ignored counts: build-macapp.py compiles every .swift
    # it finds, so a new source file would be built without being in HEAD.
    # Ignored build products (target/) do not.
    dirty = sh(["git", "status", "--porcelain", "--untracked-files=all"], root)
    facts = {"head": head, "dirty": bool(dirty),
             "github_sha": environ.get("GITHUB_SHA", ""), "github_ref": environ.get("GITHUB_REF", "")}
    # On a pull request the checkout is the merge commit GITHUB_SHA names.
    if facts["github_sha"] and facts["github_sha"] != head:
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


def bundle_id(app: str) -> str | None:
    try:
        with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except (OSError, plistlib.InvalidFileException):
        return None


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
    os.makedirs(out, exist_ok=False)
    shutil.copytree(app, os.path.join(out, "Tako.app"), symlinks=True)
    manifest["app"] = tree_hashes(os.path.join(out, "Tako.app"))
    if runner:
        shutil.copy2(runner, os.path.join(out, "tako-e2e"))
        shutil.copy2(runner + ".inputs", os.path.join(out, "tako-e2e.inputs"))
        manifest["runner"] = {"tako-e2e": sha256(os.path.join(out, "tako-e2e")),
                              "tako-e2e.inputs": sha256(os.path.join(out, "tako-e2e.inputs"))}
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    return manifest


def verify(prebuilt: str, require_zmx: bool, root: str = ROOT, environ=os.environ, current: dict | None = None) -> dict:
    with open(os.path.join(prebuilt, "manifest.json")) as f:
        manifest = json.load(f)
    app = os.path.join(prebuilt, "Tako.app")
    compare(manifest, current or describe(app, None, root, environ), require_zmx)
    check_files(manifest["app"], app, "prebuilt app")
    for name, digest in manifest.get("runner", {}).items():
        if not os.path.isfile(os.path.join(prebuilt, name)) or sha256(os.path.join(prebuilt, name)) != digest:
            raise Mismatch(f"prebuilt runner: {name} changed or missing")
    return manifest


def reseal(app: str, bundle_id: str) -> None:
    sh(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {bundle_id}", os.path.join(app, "Contents/Info.plist")])
    sh(["codesign", "--force", "--sign", "-", app])


def install(prebuilt: str, app_dir: str, bundle_id: str, require_zmx: bool, root: str = ROOT,
            environ=os.environ, current: dict | None = None, resealer=reseal) -> dict:
    manifest = verify(prebuilt, require_zmx, root, environ, current)
    app = os.path.join(app_dir, "Tako.app")
    if os.path.exists(app):
        shutil.rmtree(app)
    os.makedirs(app_dir, exist_ok=True)
    shutil.copytree(os.path.join(prebuilt, "Tako.app"), app, symlinks=True)
    resealer(app, bundle_id)
    after = tree_hashes(app)
    changed = sorted(k for k in set(after) | set(manifest["app"]) if after.get(k) != manifest["app"].get(k))
    if not set(changed) <= RESEALED:
        raise Mismatch(f"resealing changed more than its identity: {', '.join(sorted(set(changed) - RESEALED))}")
    if manifest.get("runner"):
        target = os.path.join(root, "target")
        os.makedirs(target, exist_ok=True)
        for name in ("tako-e2e", "tako-e2e.inputs"):
            shutil.copy2(os.path.join(prebuilt, name), os.path.join(target, name))
    with open(os.path.join(prebuilt, "manifest.json"), "rb") as f:
        source = hashlib.sha256(f.read()).hexdigest()
    receipt = {"prebuilt_manifest_sha256": source, "bundle_id": bundle_id, "app": app,
               "resealed": changed, "files": after, "runner_installed": bool(manifest.get("runner"))}
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
