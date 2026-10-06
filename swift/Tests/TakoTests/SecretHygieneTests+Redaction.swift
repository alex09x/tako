/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@MainActor
extension SecretHygieneTests {

    @Test func testUserDefinedRedactionPatternsForPersistedSnapshots() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }

        try redactor.addPattern("sk-ant-[0-9a-zA-Z\\-_]+")
        try redactor.addPattern("Bearer\\s+[0-9a-zA-Z\\-_]+")

        #expect(redactor.hasPatterns)
        #expect(redactor.patterns.count == 2)

        // Rejection of pathological backtracking patterns (ReDoS safety)
        #expect(throws: RedactionPatternError.self) {
            try redactor.addPattern("^(a+)+$")
        }
        #expect(throws: RedactionPatternError.self) {
            try redactor.addPattern("(a*)*")
        }
        #expect(throws: RedactionPatternError.self) {
            try redactor.addPattern("([0-9]+)+")
        }

        // 1. Text redaction in exported snapshot scrollback
        let originalText = "Authentication succeeded with sk-ant-api03-abcdef123456 and header Bearer eyJhbGciOiJIUzI1NiJ9. Welcome!"
        let redactedText = redactor.redact(originalText)
        #expect(redactedText == "Authentication succeeded with [REDACTED] and header [REDACTED]. Welcome!")
        #expect(!redactedText.contains("sk-ant"))
        #expect(!redactedText.contains("eyJhbGci"))

        // 2. Binary checkpoint data redaction with CRC32 update
        let payloadString = "Session log: user authenticated with sk-ant-api03-abcdef123456 token."
        let payloadBytes = [UInt8](payloadString.utf8)
        let initialCRC = SessionSnapshotRedactor.computeCRC32(data: payloadBytes)

        var checkpoint = Data("TKCK".utf8)
        var version: UInt32 = 5
        var flags: UInt32 = 0
        var payloadLen: UInt32 = UInt32(payloadBytes.count)
        var crcLE = initialCRC.littleEndian

        withUnsafeBytes(of: &version) { checkpoint.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { checkpoint.append(contentsOf: $0) }
        withUnsafeBytes(of: &payloadLen) { checkpoint.append(contentsOf: $0) }
        withUnsafeBytes(of: &crcLE) { checkpoint.append(contentsOf: $0) }
        checkpoint.append(contentsOf: payloadBytes)

        #expect(checkpoint.count == 20 + payloadBytes.count)

        // Redact binary checkpoint
        let redactedCheckpoint = redactor.redact(checkpoint: checkpoint)
        #expect(redactedCheckpoint.count == checkpoint.count)

        // Secret should not be present in redacted data
        let redactedDataString = String(decoding: redactedCheckpoint, as: UTF8.self)
        #expect(!redactedDataString.contains("sk-ant-api03-abcdef123456"))

        // Header checksum must match the new masked payload
        let newPayload = [UInt8](redactedCheckpoint.dropFirst(20))
        let expectedCRC = SessionSnapshotRedactor.computeCRC32(data: newPayload)
        let headerCRC = redactedCheckpoint.dropFirst(16).prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(headerCRC == expectedCRC)
    }

    // MARK: - Real Terminal Checkpoint Cell Redaction & Import Test

    @Test func testRealBinaryCheckpointRedactsTerminalCellsAndRestoresSuccessfully() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }

        try redactor.addPattern("sk-[A-Za-z0-9\\-_]+")
        try redactor.addPattern("postgres://[^\\s]+")

        let core = TakoCore(cols: 80, rows: 24)
        // Feed terminal sequence so that text is placed into actual 32-bit grid cells
        core.feed(bytes: Data("Secret API: sk-live9876543210abcdef\r\nDATABASE_URL=postgres://alice:secret123@db.prod:5432/main\r\n".utf8))

        let rawBuffer = core.bufferText()
        #expect(rawBuffer.contains("sk-live9876543210abcdef"))
        #expect(rawBuffer.contains("postgres://alice:secret123@db.prod:5432/main"))

        // Export real binary checkpoint from engine
        let checkpoint = try core.checkpointExport(flags: 0, maxBytes: 0)
        #expect(checkpoint.count >= 20)
        #expect(checkpoint.prefix(4) == Data("TKCK".utf8))

        // Redact the real binary checkpoint
        let redactedCheckpoint = redactor.redact(checkpoint: checkpoint)

        // The raw secret should no longer appear anywhere in the checkpoint binary data
        let rawCheckpointString = String(decoding: redactedCheckpoint, as: UTF8.self)
        #expect(!rawCheckpointString.contains("sk-live9876543210abcdef"))
        #expect(!rawCheckpointString.contains("postgres://alice:secret123@db.prod:5432/main"))

        // Import the redacted checkpoint into a fresh TakoCore instance to verify structure and CRC integrity
        let restoredCore = TakoCore(cols: 80, rows: 24)
        try restoredCore.checkpointImport(blob: redactedCheckpoint)

        let restoredText = restoredCore.bufferText()
        #expect(!restoredText.contains("sk-live9876543210abcdef"))
        #expect(!restoredText.contains("postgres://alice:secret123@db.prod:5432/main"))
        #expect(restoredText.contains("Secret API: ***********************"))
        #expect(restoredText.contains("DATABASE_URL=********************************************"))
    }

    // MARK: - Finding 1: Resume Set Rejection on Secure-Input Panes

    @Test func testResumeSetRejectedOnSecureInputPanes() async throws {
        let surface = makeSurfaceView()
        defer { surface.close() }

        surface.isSecureInputMode = true
        defer { surface.isSecureInputMode = false }

        let pane = ControlCommands.Pane(surface: surface, windowID: "win-1", tabID: "tab-1", stableTabID: "tab-1")
        let all = [pane]
        let allScopes = Set(ControlScope.allCases)

        let req = ControlRequest(
            cmd: "resume",
            args: [
                "action": .string("set"),
                "target": .string(surface.id.uuidString),
                "argv": .array([.string("sh"), .string("-c"), .string("echo secret")]),
                "cwd": .string("/tmp"),
            ],
            from: nil,
            scopes: allScopes
        )

        let res = ControlCommands.handle(req, all: all)
        guard case .failure(let err) = res else {
            Issue.record("resume set must be rejected for secure-input panes")
            return
        }
        #expect(err.code == ControlError.Code.disabled)
        #expect(ResumeSessionStore.shared.record(for: surface.id) == nil)
    }

    // MARK: - Finding 2: Legacy Resume Records Sanitized on Load

    @Test func testLegacyResumeRecordsSanitizedOnLoadAndRewritten() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ResumeSessionStore(directory: tempDir)
        let paneId = UUID()

        // Create a raw legacy JSON file directly on disk containing sensitive keys
        let legacyJson: [String: Any] = [
            "argv": ["python3", "app.py"],
            "cwd": "/app",
            "env": [
                "PATH": "/usr/bin:/bin",
                "DATABASE_URL": "postgres://user:password@db.local:5432/mydb",
                "MY_PASSPHRASE": "super-secret-phrase",
                "NORMAL_VAR": "hello"
            ],
            "recordedAt": Date().timeIntervalSinceReferenceDate,
            "isImported": false
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJson)
        let fileUrl = tempDir.appendingPathComponent(paneId.uuidString).appendingPathExtension("json")
        try data.write(to: fileUrl)

        // Verify the raw file on disk currently has DATABASE_URL
        let initialDiskContent = try String(contentsOf: fileUrl, encoding: .utf8)
        #expect(initialDiskContent.contains("DATABASE_URL"))
        #expect(initialDiskContent.contains("MY_PASSPHRASE"))

        // Load record via store.record(for:)
        guard let loaded = store.record(for: paneId) else {
            Issue.record("Failed to load legacy resume record")
            return
        }

        // Environment must be sanitized in memory
        #expect(loaded.env["PATH"] == "/usr/bin:/bin")
        #expect(loaded.env["NORMAL_VAR"] == "hello")
        #expect(loaded.env["DATABASE_URL"] == nil)
        #expect(loaded.env["MY_PASSPHRASE"] == nil)

        // The file on disk must have been rewritten without the sensitive keys
        let rewrittenDiskContent = try String(contentsOf: fileUrl, encoding: .utf8)
        #expect(!rewrittenDiskContent.contains("DATABASE_URL"))
        #expect(!rewrittenDiskContent.contains("MY_PASSPHRASE"))
        #expect(rewrittenDiskContent.contains("NORMAL_VAR"))
    }

    // MARK: - Finding 3: ReDoS Safe Pattern Grammar Rejection

}
