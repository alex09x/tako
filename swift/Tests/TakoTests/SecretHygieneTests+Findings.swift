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

    @Test func testRedactionPatternRejectsAmbiguousAdjacentRepetitions() {
        // Repeated identical / overlapping quantifiers that cause catastrophic backtracking
        #expect(!SessionSnapshotRedactor.isPatternSafe("^a*a*a*a*a*a*a*b$"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("a*a*"))
        #expect(!SessionSnapshotRedactor.isPatternSafe(".*.*"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("\\w+\\w+"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("([0-9]+)+"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("((a+)?)+"))
        #expect(!SessionSnapshotRedactor.isPatternSafe("(a*)*"))

        // Legitimate safe patterns
        #expect(SessionSnapshotRedactor.isPatternSafe("sk-[A-Za-z0-9\\-_]+"))
        #expect(SessionSnapshotRedactor.isPatternSafe("Bearer\\s+[A-Za-z0-9\\-_]+"))
        #expect(SessionSnapshotRedactor.isPatternSafe("AKIA[0-9A-Z]{16}"))
        #expect(SessionSnapshotRedactor.isPatternSafe("ghp_[0-9a-zA-Z]{36}"))
    }

    // MARK: - Finding 4 & 5: Checkpoint Tail Redaction & Async Stale Invalidation

    @Test func testCheckpointTailAndAsyncSaveInvalidation() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }
        try redactor.addPattern("SUPER_SECRET_[0-9]+")

        // 1. Checkpoint with command input in tail
        let core = TakoCore(cols: 80, rows: 24)
        // Feed an OSC 133 command so that commands log records input line
        core.feed(bytes: Data("\u{1b}]133;A\u{07}SUPER_SECRET_987654321\u{1b}]133;B\u{07}\r\n".utf8))
        let checkpoint = try core.checkpointExport(flags: 0, maxBytes: 0)

        let redactedCheckpoint = redactor.redact(checkpoint: checkpoint)
        let redactedStr = String(decoding: redactedCheckpoint, as: UTF8.self)
        #expect(!redactedStr.contains("SUPER_SECRET_987654321"))

        // Must still import cleanly
        let restored = TakoCore(cols: 80, rows: 24)
        try restored.checkpointImport(blob: redactedCheckpoint)

        // 2. Async save invalidation on secure-input transition
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionSnapshotStore(directory: tempDir)
        let saver = SessionSnapshotSaver(store: store)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let surface = makeSurfaceView()
        defer { surface.close() }

        // Start save, immediately transition to secure input
        surface.core.feed(bytes: Data("Normal text\r\n".utf8))
        saver.save([surface], settings: .init(enabled: true, limit: 10_000_000, secureInput: false), asynchronous: true)

        // Enter secure input and save again
        surface.isSecureInputMode = true
        saver.save([surface], settings: .init(enabled: true, limit: 10_000_000, secureInput: false), asynchronous: true)

        // Store must not have any snapshot for the surface
        #expect(store.read(id: surface.id) == nil)
    }

    // MARK: - Finding 1: Redaction Fails Closed on Timeout

    @Test func testRedactionFailsClosedOnTimeout() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }
        try redactor.addPattern("sk-[A-Za-z0-9\\-_]+")

        let secret = "sk-ant-api03-abcdef123456"
        let normalText = "This is a normal line\nHere is a secret: \(secret)\nAnd another line."

        // 1. With timeout = 0.0 or negative, it must immediately fail closed without leaking the secret
        let immediateTimeout = redactor.redact(normalText, timeout: 0.0)
        #expect(!immediateTimeout.contains(secret))
        #expect(immediateTimeout.contains("[REDACTED]"))

        // 2. Negative timeout must also fail closed
        let negativeTimeout = redactor.redact(normalText, timeout: -1.0)
        #expect(!negativeTimeout.contains(secret))
        #expect(negativeTimeout.contains("[REDACTED]"))

        // 3. Normal redaction with sufficient timeout succeeds
        let normalRedacted = redactor.redact(normalText, timeout: 1.0)
        #expect(!normalRedacted.contains(secret))
        #expect(normalRedacted.contains("Here is a secret: [REDACTED]"))
        #expect(normalRedacted.contains("This is a normal line"))
    }

    // MARK: - Finding 2: Chunk Boundary Carry Window Redaction

    @Test func testRedactionOverlappingChunkBoundary() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }
        try redactor.addPattern("sk-[A-Za-z0-9\\-_]+")

        let secret = "sk-ant-api03-boundarysecret123"
        // Place the secret so that it straddles character offset 4096
        // Offset 4090 to 4120 in a 10,000-character line
        let prefix = String(repeating: ".", count: 4090)
        let suffix = String(repeating: ".", count: 6000)
        let longLine = prefix + secret + suffix

        #expect(longLine.count > 4096)
        let secretStart = 4090
        let secretEnd = 4090 + secret.count
        #expect(secretStart < 4096 && secretEnd > 4096) // Straddles 4096 boundary

        let redacted = redactor.redact(longLine, timeout: 2.0)
        #expect(!redacted.contains(secret))
        #expect(redacted.contains("[REDACTED]"))

        // Verify non-secret characters around the boundary are intact
        #expect(redacted.hasPrefix(prefix))
        #expect(redacted.hasSuffix(suffix))
        #expect(redacted == prefix + "[REDACTED]" + suffix)

        // Also test multiple secrets straddling consecutive chunk boundaries
        let secondSecret = "sk-ant-api03-secondsecret456"
        // Place second secret at offset 8180 (straddling next boundary)
        let middle = String(repeating: ".", count: 8180 - secretEnd)
        let multiChunkLine = prefix + secret + middle + secondSecret + suffix
        let multiRedacted = redactor.redact(multiChunkLine, timeout: 2.0)
        #expect(!multiRedacted.contains(secret))
        #expect(!multiRedacted.contains(secondSecret))
        #expect(multiRedacted == prefix + "[REDACTED]" + middle + "[REDACTED]" + suffix)
    }

    // MARK: - Finding 3: Unbounded Match Span Does Not Leak Tail

    @Test func testRedactionUnboundedMatchSpanDoesNotLeakTail() throws {
        let redactor = SessionSnapshotRedactor.shared
        defer { redactor.clearPatterns() }
        try redactor.addPattern("sk-[A-Za-z0-9\\-_]+")

        // 1. Secret span longer than initial window (6144), e.g. 8000 characters:
        // Window expands to establish match completion and redacts the full token without leaking the tail.
        let tokenBody = String(repeating: "x", count: 8000)
        let longSecret = "sk-" + tokenBody
        let prefix = String(repeating: ".", count: 2000)
        let suffix = String(repeating: ".", count: 2000)
        let line = prefix + longSecret + suffix

        let redacted = redactor.redact(line, timeout: 2.0)
        #expect(!redacted.contains("sk-"))
        #expect(!redacted.contains(String(repeating: "x", count: 50)))
        #expect(redacted.contains("[REDACTED]"))
        #expect(redacted == prefix + "[REDACTED]" + suffix)

        // 2. Secret span that exceeds maximum expanded window (32768):
        // Fails closed by replacing with [REDACTED], ensuring the tail is never leaked.
        let hugeBody = String(repeating: "y", count: 40000)
        let hugeSecret = "sk-" + hugeBody
        let hugeLine = prefix + hugeSecret + suffix

        let hugeRedacted = redactor.redact(hugeLine, timeout: 2.0)
        #expect(!hugeRedacted.contains("sk-"))
        #expect(!hugeRedacted.contains(String(repeating: "y", count: 50)))
        #expect(hugeRedacted.contains("[REDACTED]"))
    }
}


}
