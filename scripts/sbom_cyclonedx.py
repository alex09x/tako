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
from sbom_models import build_cargo_maps, get_direct_cargo_dependencies, resolve_dependency


def generate_cyclonedx(version, commit, cargo_pkgs, swift_pkgs, timestamp):
    """Generates a CycloneDX 1.5 JSON document with precise dependency graph."""
    seed = f"tako-{version}-{commit}"
    doc_uuid = str(uuid.uuid5(uuid.NAMESPACE_DNS, seed))

    by_name_ver, by_name = build_cargo_maps(cargo_pkgs)
    direct_cargo = get_direct_cargo_dependencies(cargo_pkgs, by_name_ver, by_name)

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

    # Root dependsOn connects to direct dependencies only
    root_depends_on = []
    for pkg in swift_pkgs:
        root_depends_on.append(f"pkg:swift/github.com/alex09x/tako/{pkg['name']}@{pkg['version']}")
    for pkg in direct_cargo:
        root_depends_on.append(f"pkg:cargo/{pkg['name']}@{pkg['version']}")

    dependencies.append({
        "ref": root_ref,
        "dependsOn": root_depends_on
    })

    # Swift component definitions and leaf dependencies
    for pkg in swift_pkgs:
        name = pkg["name"]
        ver = pkg["version"]
        bom_ref = f"pkg:swift/github.com/alex09x/tako/{name}@{ver}"

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
            "ref": bom_ref,
            "dependsOn": []
        })

    # Cargo components and crate-to-crate dependencies
    for pkg in cargo_pkgs:
        name = pkg["name"]
        ver = pkg["version"]
        if name in ("tako", "tako-core"):
            continue

        bom_ref = f"pkg:cargo/{name}@{ver}"
        comp = {
            "bom-ref": bom_ref,
            "type": "library",
            "name": name,
            "version": ver,
            "purl": bom_ref,
            "scope": "required"
        }
        lic = pkg.get("license")
        if lic and lic != "NOASSERTION":
            if " " in lic:
                comp["licenses"] = [{"expression": lic}]
            else:
                comp["licenses"] = [{"license": {"id": lic}}]
        if pkg.get("checksum"):
            comp["hashes"] = [
                {"alg": "SHA-256", "content": pkg["checksum"]}
            ]
        components.append(comp)

        crate_depends_on = []
        for dep_spec in pkg.get("dependencies", []):
            dep_pkg = resolve_dependency(dep_spec, by_name_ver, by_name)
            if dep_pkg and dep_pkg["name"] not in ("tako", "tako-core"):
                dep_ref = f"pkg:cargo/{dep_pkg['name']}@{dep_pkg['version']}"
                if dep_ref not in crate_depends_on:
                    crate_depends_on.append(dep_ref)

        dependencies.append({
            "ref": bom_ref,
            "dependsOn": crate_depends_on
        })

    return {
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
