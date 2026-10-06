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

"""Release dependency graph resolver for Cargo builds and SBOM generation."""

import os
import subprocess
from sbom_models import (
    build_cargo_maps,
    parse_cargo_lock,
    resolve_dependency,
    tomllib,
    ROOT,
)


def derive_manifest_direct_deps(features_spec=""):
    """Derives direct non-dev dependencies from Cargo.toml given an active feature set."""
    manifest_path = os.path.join(ROOT, "Cargo.toml")
    if not os.path.isfile(manifest_path):
        return []

    active_features = [f.strip() for f in features_spec.split(",") if f.strip()]
    if tomllib is not None:
        with open(manifest_path, "rb") as f:
            manifest = tomllib.load(f)
        deps_table = manifest.get("dependencies", {})
        features_table = manifest.get("features", {})
    else:
        deps_table = {}
        features_table = {}
        current_section = None
        with open(manifest_path, "r", encoding="utf-8") as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("[") and stripped.endswith("]"):
                    current_section = stripped[1:-1].strip()
                    continue
                if current_section == "dependencies" and "=" in stripped:
                    key = stripped.split("=")[0].strip()
                    opt = "optional = true" in stripped
                    deps_table[key] = {"optional": opt}
                elif current_section == "features" and "=" in stripped:
                    k, v = stripped.split("=", 1)
                    k = k.strip()
                    items = [x.strip().strip('"').strip("'") for x in v.strip().strip("[]").split(",") if x.strip()]
                    features_table[k] = items

    for f in active_features:
        if f not in features_table and f != "default":
            raise RuntimeError(f"Unknown feature '{f}' requested in --features '{features_spec}'")

    direct = set()
    for name, spec in deps_table.items():
        if isinstance(spec, dict):
            if not spec.get("optional", False):
                direct.add(name)
        else:
            direct.add(name)

    feat_queue = list(active_features)
    visited_feats = set()
    while feat_queue:
        feat = feat_queue.pop(0)
        if feat in visited_feats:
            continue
        visited_feats.add(feat)
        for item in features_table.get(feat, []):
            if item.startswith("dep:"):
                dep_name = item[4:]
                if dep_name in deps_table:
                    direct.add(dep_name)
            elif "/" in item:
                dep_name = item.split("/")[0]
                if dep_name in deps_table:
                    direct.add(dep_name)
            elif item in features_table:
                feat_queue.append(item)
    return sorted(direct)


def resolve_release_cargo_packages(target="aarch64-apple-darwin", features="ssh"):
    """Resolves Cargo packages for the actual release build configuration.

    Filters out dev-dependencies and inactive optional features using cargo metadata,
    retaining only the packages built into the release artifact.
    Falls back to Cargo.lock exact-package traversal if cargo metadata is unavailable.
    """
    cargo_lock_path = os.path.join(ROOT, "Cargo.lock")
    lock_pkgs = parse_cargo_lock(cargo_lock_path)
    checksum_map = {(p["name"], p["version"]): p.get("checksum", "") for p in lock_pkgs}

    metadata_error = None
    try:
        import json
        cmd = [
            "cargo", "metadata",
            "--format-version", "1",
            "--features", features,
            "--filter-platform", target,
            "--offline"
        ]
        res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if res.returncode != 0:
            cmd.pop()
            res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)

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
    # SBOM requires Cargo metadata evaluation. Fail closed with a clear error rather than
    # guessing or emitting foreign target packages (e.g. r-efi, wasi) in an Apple release SBOM.
    err_msg = (
        f"Cannot accurately resolve target-specific release dependency graph for target='{target}' "
        f"and features='{features}' without cargo metadata: {metadata_error}. "
        f"Ensure cargo is installed and available in PATH, or specify --include-all-lockfile "
        f"to generate an unpruned workspace lockfile inventory."
    )
    raise RuntimeError(err_msg)
