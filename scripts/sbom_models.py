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

"""Package metadata and lockfile parsers for SBOM generation."""

import datetime
import os
import re
import subprocess

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib  # type: ignore
    except ImportError:
        tomllib = None  # type: ignore


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def get_git_info():
    """Returns (commit_hash, tag_or_version) from git if available."""
    commit = os.environ.get("GITHUB_SHA", "")
    if not commit:
        try:
            r = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True)
            if r.returncode == 0:
                commit = r.stdout.strip()
        except Exception:
            commit = ""

    version = os.environ.get("TAKO_VERSION", "")
    if not version:
        try:
            r = subprocess.run(["git", "describe", "--tags", "--abbrev=0"], cwd=ROOT, capture_output=True, text=True)
            if r.returncode == 0:
                version = r.stdout.strip().lstrip("v")
        except Exception:
            pass
    if not version:
        version = "0.1.0"

    return commit or "0000000000000000000000000000000000000000", version


def parse_cargo_lock(lock_path):
    """Parses Cargo.lock and returns a list of package dictionaries."""
    if not os.path.isfile(lock_path):
        return []

    if tomllib is not None:
        with open(lock_path, "rb") as f:
            data = tomllib.load(f)

        packages = []
        for pkg in data.get("package", []):
            packages.append({
                "name": pkg.get("name", ""),
                "version": pkg.get("version", ""),
                "source": pkg.get("source", ""),
                "checksum": pkg.get("checksum", ""),
                "dependencies": pkg.get("dependencies", []),
                "ecosystem": "cargo",
            })
        return packages

    # Zero-dependency fallback parser for systems without tomllib/tomli
    packages = []
    current_pkg = None
    in_dependencies = False

    with open(lock_path, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            if stripped == "[[package]]":
                if current_pkg and current_pkg.get("name"):
                    packages.append(current_pkg)
                current_pkg = {
                    "name": "",
                    "version": "",
                    "source": "",
                    "checksum": "",
                    "dependencies": [],
                    "ecosystem": "cargo",
                }
                in_dependencies = False
                continue

            if current_pkg is None:
                continue

            if in_dependencies:
                if stripped == "]":
                    in_dependencies = False
                elif stripped.startswith('"'):
                    dep_val = stripped.strip('",')
                    current_pkg["dependencies"].append(dep_val)
                continue

            if stripped == "dependencies = [":
                in_dependencies = True
                continue

            if "=" in line:
                key, val = line.split("=", 1)
                key = key.strip()
                val = val.strip().strip('"')
                if key in ("name", "version", "source", "checksum"):
                    current_pkg[key] = val

    if current_pkg and current_pkg.get("name"):
        packages.append(current_pkg)

    return packages


def parse_swift_packages():
    """Extracts Swift binary targets and package metadata."""
    packages = []
    root_pkg = os.path.join(ROOT, "Package.swift")
    if os.path.isfile(root_pkg):
        with open(root_pkg, "r", encoding="utf-8") as f:
            content = f.read()
        name_m = re.search(r'binaryTarget\s*\(\s*name:\s*"([^"]+)"', content)
        url_m = re.search(r'url:\s*"([^"]+)"', content)
        chk_m = re.search(r'checksum:\s*"([^"]+)"', content)
        if name_m and url_m and chk_m:
            packages.append({
                "name": name_m.group(1),
                "version": "0.1.7",
                "url": url_m.group(1),
                "checksum": chk_m.group(3) if chk_m.lastindex and chk_m.lastindex >= 3 else chk_m.group(1),
                "ecosystem": "swift",
            })
    return packages


def get_timestamp():
    """Returns deterministic or current ISO 8601 UTC timestamp."""
    source_date_epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if source_date_epoch:
        try:
            dt = datetime.datetime.fromtimestamp(int(source_date_epoch), tz=datetime.timezone.utc)
            return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            pass
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_cargo_maps(cargo_pkgs):
    """Builds lookup maps for cargo packages by (name, version) and by name."""
    by_name_ver = {}
    by_name = {}
    for pkg in cargo_pkgs:
        by_name_ver[(pkg["name"], pkg["version"])] = pkg
        by_name.setdefault(pkg["name"], []).append(pkg)
    return by_name_ver, by_name


def resolve_dependency(dep_spec, by_name_ver, by_name):
    """Resolves a Cargo.lock dependency entry string to a package dict."""
    parts = dep_spec.strip().split()
    if not parts:
        return None
    name = parts[0]
    if len(parts) > 1:
        ver = parts[1]
        if (name, ver) in by_name_ver:
            return by_name_ver[(name, ver)]
    candidates = by_name.get(name, [])
    if candidates:
        return candidates[0]
    return None


def get_direct_cargo_dependencies(cargo_pkgs, by_name_ver=None, by_name=None):
    """Finds direct dependencies of the root tako / tako-core crate."""
    direct = [p for p in cargo_pkgs if p.get("is_direct")]
    if direct:
        return direct
    tako_pkg = next((p for p in cargo_pkgs if p["name"] in ("tako-core", "tako")), None)
    if not tako_pkg:
        return []
    if by_name_ver is None or by_name is None:
        by_name_ver, by_name = build_cargo_maps(cargo_pkgs)
    for dep_str in tako_pkg.get("dependencies", []):
        resolved = resolve_dependency(dep_str, by_name_ver, by_name)
        if resolved and resolved not in direct:
            direct.append(resolved)
    return direct


def resolve_release_cargo_packages(target="aarch64-apple-darwin", features="ssh"):
    """Resolves Cargo packages for the actual release build configuration.

    Filters out dev-dependencies and inactive optional features using cargo metadata,
    retaining only the packages built into the release artifact.
    Falls back to Cargo.lock traversal if cargo metadata is unavailable.
    """
    cargo_lock_path = os.path.join(ROOT, "Cargo.lock")
    lock_pkgs = parse_cargo_lock(cargo_lock_path)
    checksum_map = {(p["name"], p["version"]): p.get("checksum", "") for p in lock_pkgs}

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

    # Fallback path: validate build configuration and dynamically derive dependencies from manifest
    if target and not ("apple" in target or "darwin" in target):
        err_msg = f"Cannot resolve release dependency graph for non-Apple target '{target}' without cargo metadata"
        if metadata_error:
            err_msg += f" (cargo metadata failed: {metadata_error})"
        raise RuntimeError(err_msg)

    direct_names = set(derive_manifest_direct_deps(features))
    by_name_ver, by_name = build_cargo_maps(lock_pkgs)

    direct_packages = set()
    tako_lock = next((p for p in lock_pkgs if p["name"] in ("tako", "tako-core")), None)
    if tako_lock:
        for dep_str in tako_lock.get("dependencies", []):
            dep_nm = dep_str.split()[0]
            if dep_nm in direct_names:
                resolved = resolve_dependency(dep_str, by_name_ver, by_name)
                if resolved:
                    direct_packages.add((resolved["name"], resolved["version"]))

    visited_names = set()
    queue = list(direct_names)
    while queue:
        nm = queue.pop(0)
        if nm in visited_names:
            continue
        visited_names.add(nm)
        for cand in by_name.get(nm, []):
            for dep in cand.get("dependencies", []):
                dep_nm = dep.split()[0]
                if ("apple" in target or "darwin" in target) and any(dep_nm.startswith(p) for p in ("windows", "redox", "linux")):
                    continue
                if dep_nm not in visited_names and dep_nm not in ("tako", "tako-core"):
                    queue.append(dep_nm)

    filtered_pkgs = []
    for pkg in lock_pkgs:
        if pkg["name"] in visited_names and pkg["name"] not in ("tako", "tako-core"):
            pkg_copy = dict(pkg)
            pkg_copy["is_direct"] = ((pkg["name"], pkg["version"]) in direct_packages)
            filtered_pkgs.append(pkg_copy)
    return filtered_pkgs


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
