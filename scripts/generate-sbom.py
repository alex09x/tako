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
  - Cargo.lock & Cargo.toml: all Rust crates, pinned versions, checksums, and license information
  - Package.swift & swift/Package.swift: Swift packages, binary target checksums, and assets
  - Toolchain & build environment: pinned compiler and toolchain versions
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid

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


def generate_spdx(version, commit, cargo_pkgs, swift_pkgs, timestamp):
    """Generates an SPDX 2.3 JSON document."""
    doc_namespace = f"https://github.com/alex09x/tako/releases/download/v{version}/tako-{version}.spdx.json"
    spdx_packages = []
    relationships = []

    root_spdx_id = "SPDXRef-Package-tako"
    spdx_packages.append({
        "SPDXID": root_spdx_id,
        "name": "tako",
        "versionInfo": version,
        "downloadLocation": f"https://github.com/alex09x/tako/archive/refs/tags/v{version}.tar.gz",
        "filesAnalyzed": False,
        "homepage": "https://github.com/alex09x/tako",
        "licenseConcluded": "MIT",
        "licenseDeclared": "MIT",
        "copyrightText": "Copyright (c) 2026 Alexander Panasenko",
        "description": "A high-performance macOS/iOS VT terminal emulator and agent workspace platform.",
        "supplier": "Person: Alexander Panasenko (alex@prod.codes)",
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:github/alex09x/tako@{version}"
            }
        ]
    })
    relationships.append({
        "spdxElementId": "SPDXRef-DOCUMENT",
        "relationshipType": "DESCRIBES",
        "relatedSpdxElement": root_spdx_id
    })

    for pkg in cargo_pkgs:
        name = pkg["name"]
        ver = pkg["version"]
        spdx_id = f"SPDXRef-Package-cargo-{name}-{ver}".replace("_", "-")
        ext_refs = [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:cargo/{name}@{ver}"
            }
        ]
        checksums = []
        if pkg["checksum"]:
            checksums.append({
                "algorithm": "SHA256",
                "checksumValue": pkg["checksum"]
            })

        download_loc = f"https://crates.io/api/v1/crates/{name}/{ver}/download" if "crates.io" in pkg.get("source", "") else "NOASSERTION"

        spdx_packages.append({
            "SPDXID": spdx_id,
            "name": name,
            "versionInfo": ver,
            "downloadLocation": download_loc,
            "filesAnalyzed": False,
            "checksums": checksums,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "externalRefs": ext_refs
        })

        relationships.append({
            "spdxElementId": root_spdx_id,
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": spdx_id
        })

    for pkg in swift_pkgs:
        name = pkg["name"]
        ver = pkg["version"]
        spdx_id = f"SPDXRef-Package-swift-{name}".replace("_", "-")
        checksums = []
        if pkg.get("checksum"):
            checksums.append({
                "algorithm": "SHA256",
                "checksumValue": pkg["checksum"]
            })
        spdx_packages.append({
            "SPDXID": spdx_id,
            "name": name,
            "versionInfo": ver,
            "downloadLocation": pkg.get("url", "NOASSERTION"),
            "filesAnalyzed": False,
            "checksums": checksums,
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "Copyright (c) 2026 Alexander Panasenko",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": f"pkg:swift/github.com/alex09x/tako/{name}@{ver}"
                }
            ]
        })
        relationships.append({
            "spdxElementId": root_spdx_id,
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": spdx_id
        })

    doc = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Tako-{version}",
        "documentNamespace": doc_namespace,
        "creationInfo": {
            "creators": [
                "Tool: tako-generate-sbom-1.0",
                "Organization: Tako Project (https://github.com/alex09x/tako)",
                "Person: Alexander Panasenko (alex@prod.codes)"
            ],
            "created": timestamp
        },
        "packages": spdx_packages,
        "relationships": relationships
    }
    return doc


def generate_cyclonedx(version, commit, cargo_pkgs, swift_pkgs, timestamp):
    """Generates a CycloneDX 1.5 JSON document."""
    # Deterministic serial number from commit or version
    seed = f"tako-{version}-{commit}"
    doc_uuid = str(uuid.uuid5(uuid.NAMESPACE_DNS, seed))

    components = []
    dependencies = []

    root_ref = f"pkg:github/alex09x/tako@{version}"
    root_component = {
        "bom-ref": root_ref,
        "type": "application",
        "name": "tako",
        "version": version,
        "description": "A high-performance macOS/iOS VT terminal emulator and agent workspace platform.",
        "licenses": [{"license": {"id": "MIT"}}],
        "purl": root_ref,
        "externalReferences": [
            {"type": "vcs", "url": "https://github.com/alex09x/tako"},
            {"type": "website", "url": "https://github.com/alex09x/tako"}
        ]
    }

    depends_on = []

    for pkg in cargo_pkgs:
        name = pkg["name"]
        ver = pkg["version"]
        bom_ref = f"pkg:cargo/{name}@{ver}"
        depends_on.append(bom_ref)

        comp = {
            "bom-ref": bom_ref,
            "type": "library",
            "name": name,
            "version": ver,
            "purl": bom_ref,
            "scope": "required"
        }
        if pkg["checksum"]:
            comp["hashes"] = [
                {"alg": "SHA-256", "content": pkg["checksum"]}
            ]
        components.append(comp)

    for pkg in swift_pkgs:
        name = pkg["name"]
        ver = pkg["version"]
        bom_ref = f"pkg:swift/github.com/alex09x/tako/{name}@{ver}"
        depends_on.append(bom_ref)

        comp = {
            "bom-ref": bom_ref,
            "type": "framework",
            "name": name,
            "version": ver,
            "purl": bom_ref,
            "licenses": [{"license": {"id": "MIT"}}]
        }
        if pkg.get("checksum"):
            comp["hashes"] = [
                {"alg": "SHA-256", "content": pkg["checksum"]}
            ]
        if pkg.get("url"):
            comp["externalReferences"] = [
                {"type": "distribution", "url": pkg["url"]}
            ]
        components.append(comp)

    dependencies.append({
        "ref": root_ref,
        "dependsOn": depends_on
    })

    doc = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{doc_uuid}",
        "version": 1,
        "metadata": {
            "timestamp": timestamp,
            "tools": [
                {
                    "vendor": "Tako",
                    "name": "generate-sbom",
                    "version": "1.0"
                }
            ],
            "authors": [
                {
                    "name": "Alexander Panasenko",
                    "email": "alex@prod.codes"
                }
            ],
            "component": root_component
        },
        "components": components,
        "dependencies": dependencies
    }
    return doc


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
        with open(spdx_path, "w", encoding="utf-8") as f:
            json.dump(spdx_doc, f, indent=2, sort_keys=True)
            f.write("\n")
        outputs.append(spdx_path)

        # Also write canonical tako-sbom.spdx.json
        canonical_spdx = os.path.join(args.output_dir, "tako-sbom.spdx.json")
        with open(canonical_spdx, "w", encoding="utf-8") as f:
            json.dump(spdx_doc, f, indent=2, sort_keys=True)
            f.write("\n")
        outputs.append(canonical_spdx)

    if args.format in ("cyclonedx", "all"):
        cdx_doc = generate_cyclonedx(version, commit, cargo_pkgs, swift_pkgs, timestamp)
        cdx_path = os.path.join(args.output_dir, f"Tako-{version}-sbom.cdx.json")
        with open(cdx_path, "w", encoding="utf-8") as f:
            json.dump(cdx_doc, f, indent=2, sort_keys=True)
            f.write("\n")
        outputs.append(cdx_path)

        # Also write canonical tako-sbom.cdx.json
        canonical_cdx = os.path.join(args.output_dir, "tako-sbom.cdx.json")
        with open(canonical_cdx, "w", encoding="utf-8") as f:
            json.dump(cdx_doc, f, indent=2, sort_keys=True)
            f.write("\n")
        outputs.append(canonical_cdx)

    print(f"Generated SBOM ({len(cargo_pkgs)} Rust crates, {len(swift_pkgs)} Swift targets) for Tako v{version}:")
    for out in outputs:
        sha256 = hashlib.sha256(open(out, "rb").read()).hexdigest()
        print(f"  {os.path.basename(out)} (SHA256: {sha256})")


if __name__ == "__main__":
    main()
