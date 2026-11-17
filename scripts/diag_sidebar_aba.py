#!/usr/bin/env python3
# tako — Controlled sidebar driver diagnosis (never a release gate)
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Reuse one pinned hosted app; change only the runner activity in A/B/A."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile

ARCHIVE_SHA = "b1336ea4499cd69c459b87b79d6e927825b2e39ad0c71a6606cec7d4f827cc68"
APP_SHA = "e449e76c7e16ab35f97a0c2cca4c5697d2c6be005ce309ea8b086ddaba01c220"
SOURCE = "a8a6c737eeb46c663bd37584adab857c4c2438f1"
TOOLCHAIN_SHA = "9200af6600f1d88ef4ffe754966d85334d881e8b61555eb1b0132306ef623351"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def inventory(root):
    result = {}
    for path in sorted(root.rglob("*")):
        mode = path.lstat().st_mode
        name = str(path.relative_to(root))
        if stat.S_ISLNK(mode):
            result[name] = ["link", os.readlink(path)]
        elif stat.S_ISREG(mode):
            result[name] = [sha(path), stat.S_IMODE(mode)]
        elif stat.S_ISDIR(mode):
            result[name] = ["directory", stat.S_IMODE(mode)]
        else:
            raise ValueError(f"special app file: {name}")
    return result


def verify_reseal(before, after):
    assert before.keys() == after.keys(), "reseal changed the app file set"
    changed = [name for name in before if before[name] != after[name]]
    allowed = {"Contents/Info.plist", "Contents/_CodeSignature/CodeResources", "Contents/MacOS/Tako"}
    assert set(changed) <= allowed, f"reseal changed unexpected files: {changed}"
    return changed


def extract(archive, destination):
    assert sha(archive) == ARCHIVE_SHA, "archive identity mismatch"
    with tarfile.open(archive) as package:
        members = package.getmembers()
        # This exact hosted archive was built without zmx: 76 files + 18 dirs.
        assert len(members) == 94, "archive member count changed"
        for member in members:
            parts = Path(member.name).parts
            assert parts and parts[0] == "Tako.app" and ".." not in parts
            assert member.isfile() or member.isdir() or member.issym() or member.islnk()
        package.extractall(destination, filter="data")


def validate_case(text, rc, mode):
    results = re.findall(r"^\[result\] (\S+) (\S+)$", text, re.M)
    assert len(results) == 1 and results[0][0] == "sidebar-switch-speed", results
    verdict = results[0][1]
    assert (rc == 0 and verdict == "ok") or (rc != 0 and verdict == "FAIL")
    assert text.count(f"[timing activity] latencyCritical {mode}") == 1
    assert len(re.findall(r"^\[timing boundary\] ", text, re.M)) == 15
    assert len(re.findall(r"^\[timing windows\] ", text, re.M)) == 15
    assert not re.search(r"^\[timing windows\].*after=\[\]", text, re.M), "empty window-set endpoint"
    assert "owned processes: 5 all gone" in text
    assert "owner history: unchanged since before the first launch" in text
    assert "[timing model] unavailable:" not in text
    if rc:
        assert re.search(r"a sidebar switch took \d+ ms to reach the screen", text), "unexpected scenario failure"
    return verdict


def retain_work(text, destination):
    destination.mkdir()
    copied, skipped = [], []

    def special(directory, names):
        excluded = []
        for name in names:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
                excluded.append(name)
                skipped.append(str(path))
        return excluded

    for work, sessions in re.findall(r"^work kept: ([^,\n]+)(?:, sessions ([^\n]+))?$", text, re.M):
        for raw, prefix in [(work, "tkw."), (sessions, "tkd.")]:
            if not raw:
                continue
            path = Path(raw)
            resolved = path.resolve()
            assert not path.is_symlink() and resolved.parent == Path("/private/tmp")
            assert resolved.name.startswith(prefix) and resolved.stat().st_uid == os.getuid()
            shutil.copytree(resolved, destination / resolved.name, symlinks=True, ignore=special)
            copied.append(str(resolved))
    (destination / "inventory.json").write_text(json.dumps({"copied": copied, "skipped_special": skipped}, indent=2))


def run(command, log, *, env=None, check=True):
    with log.open("wb") as output:
        completed = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, env=env)
    if check and completed.returncode:
        raise RuntimeError(f"{log.name}: exit {completed.returncode}")
    return completed.returncode


def main():
    original = Path(sys.argv[1]).resolve()
    output = Path("target/sidebar-aba").resolve()
    output.mkdir(exist_ok=False)
    statuses = []
    try:
        current = b"".join(subprocess.check_output(command) for command in [
            ["xcodebuild", "-version"], ["swift", "--version"], ["sw_vers"]])
        (output / "toolchain.txt").write_bytes(current)
        assert hashlib.sha256(current).hexdigest() == TOOLCHAIN_SHA, "hosted toolchain/OS changed"
        assert sha(original / "toolchain.txt") == TOOLCHAIN_SHA
        extract(original / "app.tar", output / "original")
        base = output / "original/Tako.app"
        assert sha(base / "Contents/MacOS/Tako") == APP_SHA
        info = plistlib.loads((base / "Contents/Info.plist").read_bytes())
        assert info["TakoSourceCommit"] == SOURCE
        run(["codesign", "--verify", "--strict", "--deep", str(base)], output / "original-signature.log")
        run(["bash", "scripts/e2e-macapp.sh", "--compile-only"], output / "runner-compile.log")
        runner_hash = sha("target/tako-e2e")
        for label, flag in [("A1", "0"), ("B", "1"), ("A2", "0")]:
            case = output / label
            case.mkdir()
            app = case / "Tako.app"
            run(["ditto", str(base), str(app)], case / "copy.log")
            before = inventory(app)
            bundle = f"com.tako-core.terminal.e2e-aba-{os.environ['GITHUB_RUN_ID']}-{label.lower()}"
            run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {bundle}", str(app / "Contents/Info.plist")], case / "identity.log")
            run(["codesign", "--force", "--sign", "-", str(app)], case / "sign.log")
            run(["codesign", "--verify", "--strict", "--deep", str(app)], case / "verify.log")
            after = inventory(app)
            receipt = {"source": SOURCE, "archive_sha": ARCHIVE_SHA, "runner_sha": runner_hash,
                       "bundle": bundle, "flag": flag, "changed": verify_reseal(before, after), "files": after}
            (case / "identity.json").write_text(json.dumps(receipt, indent=2))
            env = dict(os.environ, APP=str(app), TAKO_BUNDLE_ID=bundle, TAKO_E2E_LATENCY_CRITICAL=flag)
            rc = run(["bash", "scripts/e2e-macapp.sh", "sidebar-switch-speed"], case / "runner.log", env=env, check=False)
            text = (case / "runner.log").read_text()
            # Preserve failure state before interpreting the result or starting another case.
            retain_work(text, case / "kept-work")
            assert sha("target/tako-e2e") == runner_hash, "runner recompiled between modes"
            verdict = validate_case(text, rc, "on" if flag == "1" else "off")
            snapshot = subprocess.check_output(["ps", "-axww", "-o", "pid=,command="], text=True)
            assert snapshot.strip(), "empty GUI census"
            assert not any(str(app / "Contents/MacOS/Tako") in row for row in snapshot.splitlines()), "fixture GUI still referenced"
            statuses.append({"case": label, "flag": flag, "rc": rc, "verdict": verdict})
            print(f"{label} latencyCritical={flag}: original 250 ms gate {verdict}", flush=True)
        return 0 if all(item["rc"] == 0 for item in statuses) else 1
    finally:
        (output / "status.json").write_text(json.dumps({"cases": statuses, "complete": len(statuses) == 3}, indent=2))


if __name__ == "__main__":
    sys.exit(main())
