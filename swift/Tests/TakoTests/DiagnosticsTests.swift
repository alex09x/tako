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

@Suite("DiagnosticsTests")
struct DiagnosticsTests {
    @Test("DiagnosticsRedactor reducePath replaces home directory with tilde")
    func testReducePath() {
        let home = NSHomeDirectory()
        let path = "\(home)/workspace/project/file.txt"
        let reduced = DiagnosticsRedactor.reducePath(path)
        #expect(reduced == "~/workspace/project/file.txt")

        let nonHome = "/Library/Application Support/Tako"
        #expect(DiagnosticsRedactor.reducePath(nonHome) == nonHome)
    }

    @Test("DiagnosticsRedactor redactSecrets masks sensitive credentials")
    func testRedactSecrets() {
        let text = """
        github_token = ghp_123456789012345678901234567890
        api_key: secret_key_value_12345
        password = mySecretPassword123
        normal_config = value
        """
        let redacted = DiagnosticsRedactor.redactSecrets(in: text)
        #expect(!redacted.contains("ghp_123456789012345678901234567890"))
        #expect(!redacted.contains("secret_key_value_12345"))
        #expect(!redacted.contains("mySecretPassword123"))
        #expect(redacted.contains("normal_config = value"))
    }

    @Test("DiagnosticsRedactor masks multi-line PEM private keys")
    func testRedactMultiLinePemKey() {
        let text = """
        config_key = value
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA0m...
        secret_key_bytes_12345
        -----END RSA PRIVATE KEY-----
        after_key = normal
        """
        let redacted = DiagnosticsRedactor.redactSecrets(in: text)
        #expect(!redacted.contains("secret_key_bytes_12345"))
        #expect(!redacted.contains("RSA PRIVATE KEY"))
        #expect(redacted.contains("[REDACTED_PRIVATE_KEY]"))
        #expect(redacted.contains("config_key = value"))
        #expect(redacted.contains("after_key = normal"))
    }

    @Test("DiagnosticsExporter collects report without terminal contents by default")
    @MainActor
    func testCollectReportExcludesTerminalByDefault() {
        let report = DiagnosticsExporter.collectReport(allPanes: [], includeTerminal: false)
        #expect(!report.versions.appVersion.isEmpty)
        #expect(!report.versions.osVersion.isEmpty)
        #expect(!report.versions.arch.isEmpty)
        #expect(report.system.uptimeSeconds > 0)

        for pane in report.panes {
            #expect(pane.terminalText == nil)
        }
    }

    @Test("ControlCommands diagnose handles request correctly")
    @MainActor
    func testControlCommandsDiagnose() throws {
        ControlCommands.mode = .on
        let token = ControlGrantStore.shared.primaryToken
        let req = ControlRequest(cmd: "diagnose", args: ["include_terminal": .bool(false)], token: token)
        let response = ControlCommands.handle(req, all: [])
        switch response {
        case .ok(let result):
            #expect(result["versions"] != nil)
            #expect(result["system"] != nil)
            #expect(result["panes"] != nil)
        case .failure(let err):
            Issue.record("Expected diagnose to succeed, failed with: \(err.message)")
        }
    }

    @Test("DiagnosticsExporter writeSecurely sets 0600 permissions")
    func testWriteSecurelyPermissions() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("test-diag-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dest) }

        let sampleData = "{\"test\": true}".data(using: .utf8)!
        try DiagnosticsExporter.writeSecurely(data: sampleData, to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }
}
