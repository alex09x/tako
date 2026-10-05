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

"""CycloneDX 1.5 JSON generator for Tako releases."""

import uuid


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
