/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@Suite(.serialized) struct SupplyChainTests {

    private var repoRoot: URL {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Cargo.toml").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // MARK: - 1. Pinned Toolchain

    @Test func testRustToolchainPinned() throws {
        let toolchainPath = repoRoot.appendingPathComponent("rust-toolchain.toml")
        #expect(FileManager.default.fileExists(atPath: toolchainPath.path), "rust-toolchain.toml must exist in repo root")

        let content = try String(contentsOf: toolchainPath, encoding: .utf8)
        #expect(content.contains("channel = \"1.97.1\""), "Rust channel must be pinned to 1.97.1")
        #expect(content.contains("\"rustfmt\""), "Toolchain must include rustfmt component")
        #expect(content.contains("\"clippy\""), "Toolchain must include clippy component")
        #expect(content.contains("\"aarch64-apple-darwin\""), "Toolchain must include macOS arm64 target")
        #expect(content.contains("\"aarch64-apple-ios\""), "Toolchain must include iOS arm64 target")
        #expect(content.contains("\"aarch64-apple-ios-sim\""), "Toolchain must include iOS simulator arm64 target")
        #expect(content.contains("profile = \"minimal\""), "Toolchain profile must be minimal")
    }

    // MARK: - 2. SPDX 2.3 SBOM Generation

    @Test func testGenerateSbomSpdx() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptPath = repoRoot.appendingPathComponent("scripts/generate-sbom.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptPath,
            "--format", "spdx",
            "--version", "0.1.7",
            "--output-dir", tempDir.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["SOURCE_DATE_EPOCH"] = "1700000000"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "generate-sbom.py must succeed: \(outStr)")

        let spdxFile = tempDir.appendingPathComponent("Tako-0.1.7-sbom.spdx.json")
        #expect(FileManager.default.fileExists(atPath: spdxFile.path), "SPDX SBOM file must be generated")

        let data = try Data(contentsOf: spdxFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Generated SPDX file is not valid JSON")
            return
        }

        #expect(json["spdxVersion"] as? String == "SPDX-2.3")
        #expect(json["dataLicense"] as? String == "CC0-1.0")
        #expect(json["SPDXID"] as? String == "SPDXRef-DOCUMENT")
        #expect(json["name"] as? String == "Tako-0.1.7")

        guard let creationInfo = json["creationInfo"] as? [String: Any],
              let creators = creationInfo["creators"] as? [String] else {
            Issue.record("Missing creationInfo or creators in SPDX document")
            return
        }
        #expect(creators.contains("Person: Alexander Panasenko (alex@prod.codes)"))

        guard let packages = json["packages"] as? [[String: Any]] else {
            Issue.record("Missing packages list in SPDX document")
            return
        }

        let rootPkg = packages.first { ($0["SPDXID"] as? String) == "SPDXRef-Package-tako" }
        #expect(rootPkg != nil, "SPDX document must include root tako package")
        #expect(rootPkg?["name"] as? String == "tako")
        #expect(rootPkg?["versionInfo"] as? String == "0.1.7")
        #expect(rootPkg?["licenseConcluded"] as? String == "MIT")
        #expect(rootPkg?["supplier"] as? String == "Person: Alexander Panasenko (alex@prod.codes)")

        // Ensure cargo dependencies are documented with purl and checksums
        let libcPkg = packages.first { ($0["name"] as? String) == "libc" }
        #expect(libcPkg != nil, "SPDX document must include libc dependency")
        if let libcPkg = libcPkg {
            let checksums = libcPkg["checksums"] as? [[String: Any]] ?? []
            #expect(!checksums.isEmpty, "libc package must include SHA-256 checksum")
            let extRefs = libcPkg["externalRefs"] as? [[String: Any]] ?? []
            let purlRef = extRefs.first { ($0["referenceType"] as? String) == "purl" }
            #expect(purlRef != nil, "libc package must have purl reference")
        }

        guard let relationships = json["relationships"] as? [[String: Any]] else {
            Issue.record("Missing relationships list in SPDX document")
            return
        }
        let rootDependsOn = relationships.filter {
            ($0["relationshipType"] as? String) == "DEPENDS_ON" &&
            ($0["spdxElementId"] as? String) == "SPDXRef-Package-tako"
        }
        #expect(rootDependsOn.count >= 10 && rootDependsOn.count <= 25, "Root package must connect to direct dependencies only, got \(rootDependsOn.count)")

        let allDependsOn = relationships.filter { ($0["relationshipType"] as? String) == "DEPENDS_ON" }
        #expect(allDependsOn.count > 500, "SPDX document must record complete DAG of crate-to-crate DEPENDS_ON relationships, got \(allDependsOn.count)")
    }

    // MARK: - 3. CycloneDX 1.5 SBOM Generation

    @Test func testGenerateSbomCycloneDx() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptPath = repoRoot.appendingPathComponent("scripts/generate-sbom.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            scriptPath,
            "--format", "cyclonedx",
            "--version", "0.1.7",
            "--output-dir", tempDir.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["SOURCE_DATE_EPOCH"] = "1700000000"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "generate-sbom.py must succeed: \(outStr)")

        let cdxFile = tempDir.appendingPathComponent("Tako-0.1.7-sbom.cdx.json")
        #expect(FileManager.default.fileExists(atPath: cdxFile.path), "CycloneDX SBOM file must be generated")

        let data = try Data(contentsOf: cdxFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Generated CycloneDX file is not valid JSON")
            return
        }

        #expect(json["bomFormat"] as? String == "CycloneDX")
        #expect(json["specVersion"] as? String == "1.5")
        #expect((json["serialNumber"] as? String)?.starts(with: "urn:uuid:") == true)

        guard let metadata = json["metadata"] as? [String: Any],
              let component = metadata["component"] as? [String: Any] else {
            Issue.record("Missing metadata or root component in CycloneDX document")
            return
        }
        #expect(component["name"] as? String == "tako")
        #expect(component["version"] as? String == "0.1.7")

        guard let authors = metadata["authors"] as? [[String: Any]] else {
            Issue.record("Missing authors in CycloneDX metadata")
            return
        }
        let author = authors.first { ($0["email"] as? String) == "alex@prod.codes" }
        #expect(author != nil, "CycloneDX metadata must include Alexander Panasenko author")

        guard let components = json["components"] as? [[String: Any]] else {
            Issue.record("Missing components list in CycloneDX document")
            return
        }
        #expect(components.count >= 10, "CycloneDX document must contain all dependency components")

        let libc = components.first { ($0["name"] as? String) == "libc" }
        #expect(libc != nil, "CycloneDX document must include libc component")
        if let libc = libc {
            let hashes = libc["hashes"] as? [[String: Any]] ?? []
            #expect(!hashes.isEmpty, "libc component must have SHA-256 hash")
            #expect(libc["purl"] as? String != nil, "libc component must have purl")
        }

        guard let dependencies = json["dependencies"] as? [[String: Any]] else {
            Issue.record("Missing dependencies list in CycloneDX document")
            return
        }
        let rootDep = dependencies.first { ($0["ref"] as? String) == "pkg:github/alex09x/tako@0.1.7" }
        #expect(rootDep != nil, "CycloneDX document must include root dependency node")
        let rootDependsOn = rootDep?["dependsOn"] as? [String] ?? []
        #expect(rootDependsOn.count >= 10 && rootDependsOn.count <= 25, "Root dependency node must connect to direct dependencies only, got \(rootDependsOn.count)")

        let cratesWithDependencies = dependencies.filter {
            ($0["ref"] as? String) != "pkg:github/alex09x/tako@0.1.7" &&
            !($0["dependsOn"] as? [String] ?? []).isEmpty
        }
        #expect(cratesWithDependencies.count > 100, "CycloneDX document must record crate-to-crate dependencies, got \(cratesWithDependencies.count)")
    }

    // MARK: - 4. Reproducible Build Verification Script

    @Test func testVerifyReproducibleBuildScriptExistsAndConfigured() throws {
        let scriptPath = repoRoot.appendingPathComponent("scripts/verify-reproducible-build.sh")
        #expect(FileManager.default.fileExists(atPath: scriptPath.path), "verify-reproducible-build.sh must exist")
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath.path), "verify-reproducible-build.sh must be executable")

        let content = try String(contentsOf: scriptPath, encoding: .utf8)
        #expect(content.contains("SOURCE_DATE_EPOCH"), "Script must configure SOURCE_DATE_EPOCH")
        #expect(content.contains("ZERO_AR_DATE"), "Script must configure ZERO_AR_DATE")
        #expect(content.contains("MACOSX_DEPLOYMENT_TARGET"), "Script must configure MACOSX_DEPLOYMENT_TARGET")
        #expect(content.contains("--remap-path-prefix"), "Script must configure --remap-path-prefix")
    }

    // MARK: - 5. Reproducible Builds Documentation

    @Test func testReproducibleBuildsDocumentation() throws {
        let docPath = repoRoot.appendingPathComponent("docs/reproducible-builds.md")
        #expect(FileManager.default.fileExists(atPath: docPath.path), "docs/reproducible-builds.md must exist")

        let content = try String(contentsOf: docPath, encoding: .utf8)
        #expect(content.contains("rust-toolchain.toml"), "Documentation must reference rust-toolchain.toml")
        #expect(content.contains("Cargo.lock"), "Documentation must reference Cargo.lock")
        #expect(content.contains("SOURCE_DATE_EPOCH"), "Documentation must document SOURCE_DATE_EPOCH")
        #expect(content.contains("ZERO_AR_DATE"), "Documentation must document ZERO_AR_DATE")
        #expect(content.contains("RUSTFLAGS"), "Documentation must document RUSTFLAGS")
        #expect(content.contains("SPDX 2.3"), "Documentation must document SPDX 2.3 format")
        #expect(content.contains("CycloneDX 1.5"), "Documentation must document CycloneDX 1.5 format")
    }
}
