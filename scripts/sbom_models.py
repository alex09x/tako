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
            # Match binaryTarget(name: "...", url: "...", checksum: "...")
            bt_match = re.search(r'name:\s*"([^"]+)",\s*url:\s*"([^"]+)",\s*checksum:\s*"([^"]+)"', content, re.MULTILINE)
            if bt_match:
                packages.append({
                    "name": bt_match.group(1),
                    "version": "0.1.7",
                    "url": bt_match.group(2),
                    "checksum": bt_match.group(3),
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


def get_direct_cargo_dependencies(cargo_pkgs, by_name_ver, by_name):
    """Finds direct dependencies of the root tako / tako-core crate."""
    tako_pkg = next((p for p in cargo_pkgs if p["name"] in ("tako-core", "tako")), None)
    if not tako_pkg:
        return []
    direct = []
    for dep_str in tako_pkg.get("dependencies", []):
        resolved = resolve_dependency(dep_str, by_name_ver, by_name)
        if resolved and resolved not in direct:
            direct.append(resolved)
    return direct
