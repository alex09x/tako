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
