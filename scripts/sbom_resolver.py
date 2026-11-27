#!/usr/bin/env python3
#
# tako — Terminal emulator
# Copyright (c) 2026 Alexander Panasenko
#
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#

"""Release dependency graph resolver through Mitts for SBOM generation."""

import os
import subprocess
from sbom_models import (
    engine,
    parse_cargo_lock,
)


def engine_root():
    """The engine's crate: the pinned tako-core checkout."""
    return engine()["checkout"]


def resolve_release_cargo_packages(target="aarch64-apple-darwin", features="ssh", root=None):
    """Resolves Cargo packages for the actual release build configuration.

    The engine library in the app is the pinned tako-core release, built from
    that release's Cargo.lock with the given features; `root` defaults to its
    checkout. Filters out dev-dependencies and inactive optional features using
    Mitts metadata, retaining only the packages built into the release artifact.
    Fails closed when target-specific metadata cannot be resolved.
    """
    root = root or engine_root()
    cargo_lock_path = os.path.join(root, "Cargo.lock")
    lock_pkgs = parse_cargo_lock(cargo_lock_path)
    checksum_map = {(p["name"], p["version"]): p.get("checksum", "") for p in lock_pkgs}

    metadata_error = None
    try:
        import json
        cmd = [
            "mitts", "metadata",
            "--format-version", "1",
            "--features", features,
            "--filter-platform", target,
            # The release's own Cargo.lock as it is: never updated to
            # describe a graph the engine was not built from.
            "--locked",
            "--offline"
        ]
        res = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
        unsupported = any(marker in (res.stdout + res.stderr).lower() for marker in (
            "unsupported", "unrecognized subcommand", "unexpected argument"))
        if res.returncode != 0 and not unsupported:
            cmd.pop()
            res = subprocess.run(cmd, cwd=root, capture_output=True, text=True)

        if res.returncode == 0:
            meta = json.loads(res.stdout)
            raw_pkgs = {p["id"]: p for p in meta.get("packages", [])}
            nodes = {n["id"]: n for n in meta.get("resolve", {}).get("nodes", [])}
            root_id = meta.get("resolve", {}).get("root")

            if root_id and root_id in nodes:
                visited = set()
                queue = [root_id]
                direct_pkg_ids = set()
                dep_graph = {}

                root_node = nodes[root_id]
                for dep in root_node.get("deps", []):
                    dep_kinds = dep.get("dep_kinds", [])
                    if any(k.get("kind") != "dev" for k in dep_kinds) if dep_kinds else True:
                        direct_pkg_ids.add(dep["pkg"])

                while queue:
                    curr = queue.pop(0)
                    if curr in visited:
                        continue
                    visited.add(curr)
                    curr_node = nodes.get(curr, {})
                    curr_deps = []
                    for dep in curr_node.get("deps", []):
                        dep_kinds = dep.get("dep_kinds", [])
                        if any(k.get("kind") != "dev" for k in dep_kinds) if dep_kinds else True:
                            dep_pkg_id = dep["pkg"]
                            curr_deps.append(dep_pkg_id)
                            if dep_pkg_id not in visited:
                                queue.append(dep_pkg_id)
                    dep_graph[curr] = curr_deps

                packages = []
                for pkg_id in visited:
                    raw = raw_pkgs.get(pkg_id)
                    if not raw or raw["name"] in ("tako", "tako-core"):
                        continue
                    name = raw["name"]
                    ver = raw["version"]
                    chk = checksum_map.get((name, ver), "")
                    lic = raw.get("license") or "NOASSERTION"
                    child_deps = []
                    for child_id in dep_graph.get(pkg_id, []):
                        child_raw = raw_pkgs.get(child_id)
                        if child_raw and child_raw["name"] not in ("tako", "tako-core"):
                            child_deps.append(f"{child_raw['name']} {child_raw['version']}")
                    packages.append({
                        "name": name,
                        "version": ver,
                        "source": raw.get("source") or "",
                        "checksum": chk,
                        "license": lic,
                        "dependencies": child_deps,
                        "ecosystem": "cargo",
                        "is_direct": (pkg_id in direct_pkg_ids),
                    })
                return packages
        else:
            metadata_error = res.stderr.strip() or f"exit status {res.returncode}"
    except Exception as e:
        metadata_error = str(e)

    # Cargo.lock omits target cfg conditions, so resolving a target-accurate release
    # SBOM requires Mitts metadata evaluation. Fail closed with a clear error rather than
    # guessing or emitting foreign target packages (e.g. r-efi, wasi) in an Apple release SBOM.
    err_msg = (
        f"Cannot accurately resolve target-specific release dependency graph for target='{target}' "
        f"and features='{features}' without Mitts metadata: {metadata_error}. "
        f"Ensure mitts is installed and available in PATH, or specify --include-all-lockfile "
        f"to generate an unpruned workspace lockfile inventory."
    )
    raise RuntimeError(err_msg)
