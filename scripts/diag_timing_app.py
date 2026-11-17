#!/usr/bin/env python3
# tako — Prepare the pinned app for hosted timing diagnosis
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Verify the retained CI artifact and give its app a fresh test identity."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

import prebuilt

ARCHIVE_SHA = "9dd634e4d6cffb2d87abdb0e0c8e0861997d78b5435d0793ba4e904eeaf287ff"
SOURCE = "acae243de904a01e6d9670f2c1fb563df869ba32"
APP_FILE = "Contents/MacOS/Tako"
APP_ENTRY = "c43db3e3d12a7fc80f9e3801edc14e2e61db4ae5d3bedd9bdde8f9b39be09015:755"


def checked_member(member, destination):
    checked = tarfile.data_filter(member, destination)
    if checked is not None and checked.isfile():
        checked.mode = member.mode & 0o777
    return checked


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def prepare(archive_path, output, bundle_id):
    if not re.fullmatch(r"com\.tako-core\.terminal\.e2e-timing-[0-9]+-[0-9]+", bundle_id):
        raise ValueError("expected a fresh CI fixture bundle ID")
    if prebuilt.sha256(archive_path) != ARCHIVE_SHA:
        raise ValueError("the retained CI archive hash differs")

    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(dir=output) as unpack:
        with tarfile.open(archive_path) as archive:
            if any(Path(m.name).parts[:1] != ("prebuilt",) for m in archive.getmembers()):
                raise ValueError("unexpected archive paths")
            archive.extractall(unpack, filter=checked_member)
        root = Path(unpack) / "prebuilt"
        manifest = json.loads((root / "manifest.json").read_text())
        files = manifest["app"]
        if manifest["checkout"]["head"] != SOURCE or files[APP_FILE] != APP_ENTRY:
            raise ValueError("the retained source or app identity differs")
        original = root / "Tako.app"
        prebuilt.check_files(files, str(original), "retained CI app")
        prebuilt.require_source_stamp(str(original), SOURCE, "retained CI app")
        subprocess.run(["codesign", "--verify", "--strict", "--deep", original], check=True)
        toolchain = {
            "xcode": " ".join(command("xcodebuild", "-version").split()),
            "swiftc": command("swiftc", "--version").splitlines()[0],
            "macos_sdk": command("xcrun", "--sdk", "macosx", "--show-sdk-version"),
            "macos_sdk_build": command("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        }
        for key, value in toolchain.items():
            if value != manifest["toolchain"][key]:
                raise ValueError(f"hosted {key} changed: {value}")
        app = output / "Tako.app"
        subprocess.run(["ditto", original, app], check=True)

    info = app / "Contents/Info.plist"
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {bundle_id}", info], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", app], check=True)
    subprocess.run(["codesign", "--verify", "--strict", "--deep", app], check=True)
    after = prebuilt.tree_hashes(str(app))
    changed = {path for path in files if files[path] != after.get(path)}
    if after.keys() != files.keys() or not changed <= prebuilt.RESEALED:
        raise ValueError("the test reseal changed app files outside the allowed set")
    prebuilt.require_source_stamp(str(app), SOURCE, "resealed diagnostic app")

    identity = {
        "artifact_run": 44075043801,
        "archive_sha256": ARCHIVE_SHA,
        "app_source": SOURCE,
        "runner_source": command("git", "rev-parse", "HEAD"),
        "host": command("sw_vers"),
        "runner_toolchain": toolchain,
        "bundle_id": bundle_id,
        "changed_files": sorted(changed),
        "app_files": after,
    }
    (output / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
    print(f"Verified {len(files)} app files from {SOURCE} and made fixture {bundle_id}")


if __name__ == "__main__":
    bundle = "com.tako-core.terminal.e2e-timing-" + os.environ["GITHUB_RUN_ID"] + "-" + os.environ["GITHUB_RUN_ATTEMPT"]
    prepare(Path(sys.argv[1]), Path(sys.argv[2]), bundle)
