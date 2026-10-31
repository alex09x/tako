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

struct LayoutRecoveryArchiveTests {
    @Test func aPreLaunchCopySurvivesJournalCleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Data("previous layout".utf8)
        try LayoutRecoveryArchive.preserve(old, generation: 9, in: dir)
        try Data("obsolete".utf8).write(to: dir.appendingPathComponent("journal-8.json"))
        JournalCommitter(directory: dir, generation: 9, state: .dirty).sweep()
        #expect(try Data(contentsOf: dir.appendingPathComponent("recovery-9.json")) == old)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal-8.json").path))
    }

    @Test func missingDirectoryFailsRatherThanPretendingToPreserve() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) {
            try LayoutRecoveryArchive.preserve(Data("layout".utf8), generation: 1, in: dir)
        }
    }

    @Test func conflictingArchiveIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("first".utf8)
        try LayoutRecoveryArchive.preserve(original, generation: 1, in: dir)
        #expect(throws: (any Error).self) {
            try LayoutRecoveryArchive.preserve(Data("different".utf8), generation: 1, in: dir)
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent("recovery-1.json")) == original)
    }

    @Test func retentionKeepsTheNewestThirtyTwoCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for generation in 1...34 {
            try LayoutRecoveryArchive.preserve(Data("layout \(generation)".utf8), generation: UInt64(generation), in: dir)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.count == 32)
        #expect(!names.contains("recovery-1.json") && !names.contains("recovery-2.json"))
        #expect(names.contains("recovery-3.json") && names.contains("recovery-34.json"))
    }
}
