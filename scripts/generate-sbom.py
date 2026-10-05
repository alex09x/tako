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

"""Generate Software Bill of Materials (SBOM) in SPDX 2.3 and CycloneDX 1.5 formats.

Inspects:
  - Cargo.lock: all Rust crates, pinned versions, checksums, and license info
  - Package.swift: Swift packages, binary target checksums, and assets
  - Environment: pinned compiler and toolchain versions
"""

import argparse
import hashlib
import json
import os
import sys

# Ensure scripts directory is on sys.path
SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

from sbom_cyclonedx import generate_cyclonedx
from sbom_models import get_git_info, get_timestamp, parse_cargo_lock, parse_swift_packages, ROOT
from sbom_spdx import generate_spdx


def write_json(path, data):
    """Writes formatted JSON with trailing newline."""
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def main():
    parser = argparse.ArgumentParser(description="Generate SBOM for Tako releases (SPDX 2.3 and CycloneDX 1.5)")
    parser.add_argument("--output-dir", default=os.path.join(ROOT, "target", "macapp"), help="Directory to save generated SBOM files")
    parser.add_argument("--version", default="", help="Release version (defaults to git tag or TAKO_VERSION)")
    parser.add_argument("--format", choices=["spdx", "cyclonedx", "all"], default="all", help="Output format")
    args = parser.parse_args()

    commit, version = get_git_info()
    if args.version:
        version = args.version.lstrip("v")

    timestamp = get_timestamp()
    cargo_lock = os.path.join(ROOT, "Cargo.lock")
    cargo_pkgs = parse_cargo_lock(cargo_lock)
    swift_pkgs = parse_swift_packages()

    os.makedirs(args.output_dir, exist_ok=True)
    outputs = []

    if args.format in ("spdx", "all"):
        spdx_doc = generate_spdx(version, commit, cargo_pkgs, swift_pkgs, timestamp)
        spdx_path = os.path.join(args.output_dir, f"Tako-{version}-sbom.spdx.json")
        write_json(spdx_path, spdx_doc)
        outputs.append(spdx_path)

        canonical_spdx = os.path.join(args.output_dir, "tako-sbom.spdx.json")
        write_json(canonical_spdx, spdx_doc)
        outputs.append(canonical_spdx)

    if args.format in ("cyclonedx", "all"):
        cdx_doc = generate_cyclonedx(version, commit, cargo_pkgs, swift_pkgs, timestamp)
        cdx_path = os.path.join(args.output_dir, f"Tako-{version}-sbom.cdx.json")
        write_json(cdx_path, cdx_doc)
        outputs.append(cdx_path)

        canonical_cdx = os.path.join(args.output_dir, "tako-sbom.cdx.json")
        write_json(canonical_cdx, cdx_doc)
        outputs.append(canonical_cdx)

    print(f"Generated SBOM ({len(cargo_pkgs)} Rust crates, {len(swift_pkgs)} Swift targets) for Tako v{version}:")
    for out in outputs:
        sha256 = hashlib.sha256(open(out, "rb").read()).hexdigest()
        print(f"  {os.path.basename(out)} (SHA256: {sha256})")


if __name__ == "__main__":
    main()
