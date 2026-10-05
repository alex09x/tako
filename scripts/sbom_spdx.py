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

"""SPDX 2.3 JSON generator for Tako releases."""

from sbom_models import build_cargo_maps, get_direct_cargo_dependencies, resolve_dependency


def generate_spdx(version, commit, cargo_pkgs, swift_pkgs, timestamp):
    """Generates an SPDX 2.3 JSON document with precise dependency graph."""
    doc_namespace = f"https://github.com/alex09x/tako/releases/download/v{version}/tako-{version}.spdx.json"
    spdx_packages = []
    relationships = []
    seen_edges = set()

    by_name_ver, by_name = build_cargo_maps(cargo_pkgs)
    direct_cargo = get_direct_cargo_dependencies(cargo_pkgs, by_name_ver, by_name)

    def add_edge(src, rel, tgt):
        key = (src, rel, tgt)
        if key not in seen_edges:
            seen_edges.add(key)
            relationships.append({
                "spdxElementId": src,
                "relationshipType": rel,
                "relatedSpdxElement": tgt
            })

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
    add_edge("SPDXRef-DOCUMENT", "DESCRIBES", root_spdx_id)

    # Direct dependencies of root product: Swift packages + direct cargo dependencies
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
        add_edge(root_spdx_id, "DEPENDS_ON", spdx_id)

    for pkg in direct_cargo:
        direct_spdx_id = f"SPDXRef-Package-cargo-{pkg['name']}-{pkg['version']}".replace("_", "-")
        add_edge(root_spdx_id, "DEPENDS_ON", direct_spdx_id)

    # Locked Cargo crates and inter-package dependency edges
    for pkg in cargo_pkgs:
        name = pkg["name"]
        ver = pkg["version"]
        if name in ("tako", "tako-core"):
            continue

        spdx_id = f"SPDXRef-Package-cargo-{name}-{ver}".replace("_", "-")
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
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": f"pkg:cargo/{name}@{ver}"
                }
            ]
        })

        # Connect this crate to its actual dependencies
        for dep_spec in pkg.get("dependencies", []):
            dep_pkg = resolve_dependency(dep_spec, by_name_ver, by_name)
            if dep_pkg and dep_pkg["name"] not in ("tako", "tako-core"):
                dep_spdx_id = f"SPDXRef-Package-cargo-{dep_pkg['name']}-{dep_pkg['version']}".replace("_", "-")
                add_edge(spdx_id, "DEPENDS_ON", dep_spdx_id)

    return {
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
