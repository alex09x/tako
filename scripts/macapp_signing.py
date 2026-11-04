"""Tako — Ordered bundle signing and session-runtime hash maintenance.

Copyright (c) 2026 Alexander Panasenko
Contact: alex@prod.codes
Author: https://prod.codes/about/
Project: https://github.com/alex09x/tako
SPDX-License-Identifier: MIT
"""

import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import subprocess


def candidate_source(info, metadata=None):
    """Bind optional CI metadata to the actual downloaded bundle."""
    source = info.get("TakoSourceCommit") or None
    if metadata is not None:
        record = json.loads(Path(metadata).read_text())
        if not isinstance(record, dict):
            raise ValueError("candidate metadata must be an object")
        for field, key in [("version", "CFBundleShortVersionString"), ("build", "CFBundleVersion")]:
            if str(record.get(field)) != str(info.get(key)):
                raise ValueError(f"candidate metadata {field} does not match the app")
        recorded = record.get("source_sha")
        if source and recorded != source:
            raise ValueError("candidate metadata source does not match the app")
        source = recorded
    if source is not None and (not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source)):
        raise ValueError("candidate source must be an exact Git commit")
    return source


def verify_source_checkout(source, root, runner=subprocess.run):
    """SBOM dependencies and provenance must come from the candidate source."""
    if not source:
        raise ValueError("candidate source is unknown; provide its CI metadata before notarizing")
    result = runner(["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True)
    if result.stdout.strip() != source:
        raise ValueError(f"checkout does not match candidate source {source}; use a clean worktree at that commit")
    result = runner(["git", "status", "--porcelain", "--untracked-files=all", "--", "Cargo.toml", "Cargo.lock", "src",
                     "scripts/generate-sbom.py", "scripts/sbom_models.py", "scripts/sbom_resolver.py",
                     "scripts/sbom_spdx.py", "scripts/sbom_cyclonedx.py"],
                    cwd=root, check=True, capture_output=True, text=True)
    if result.stdout.strip():
        raise ValueError("candidate source or SBOM inputs have local edits; use a clean matching worktree")


def sign_bundle(app, identity, runner=subprocess.run):
    """Sign inner executables, refresh the helper hash, then seal the bundle.

    A deep re-sign after writing session-runtime.json changes the helper
    bytes again and invalidates its pinned identity. Never use it here.
    """
    app = Path(app)
    if not identity or not app.is_dir():
        raise ValueError("a bundle directory and signing identity are required")
    client = app / "Contents/MacOS/takoctl"
    main = app / "Contents/MacOS/Tako"
    helper = app / "Contents/Helpers/zmx"
    manifest = app / "Contents/Resources/session-runtime.json"
    root = app.resolve()
    for path in (client, main, helper, manifest):
        if not path.resolve().is_relative_to(root):
            raise ValueError("bundle signing inputs must stay inside the candidate")
    for path in (client, main):
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"missing or linked bundle executable: {path.name}")
    if helper.is_symlink() or manifest.is_symlink():
        raise ValueError("linked runtime executable or manifest is not allowed")
    if helper.exists() != manifest.exists():
        raise ValueError("the runtime executable and manifest must both exist, or both be absent")
    runtime = None
    if manifest.exists():
        runtime = json.loads(manifest.read_text())
        if runtime.get("path") != "Contents/Helpers/zmx" or not helper.is_file():
            raise ValueError("unexpected session-runtime executable path")

    command = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        command += ["--options", "runtime", "--timestamp"]

    def execute(args):
        runner([str(value) for value in args], check=True, capture_output=True, text=True)

    digest = None
    if runtime is not None:
        execute(command + [helper])
        digest = hashlib.sha256(helper.read_bytes()).hexdigest()
        runtime["sha256"] = digest
        mode = manifest.stat().st_mode & 0o777
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=manifest.parent, delete=False) as stream:
                temporary = Path(stream.name)
                json.dump(runtime, stream, indent=2, sort_keys=True)
                stream.write("\n")
            os.chmod(temporary, mode)
            os.replace(temporary, manifest)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    execute(command + [client])
    execute(command + [app])
    execute(["codesign", "--verify", "--deep", "--strict", app])
    return digest
