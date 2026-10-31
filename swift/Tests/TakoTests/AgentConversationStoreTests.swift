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

@Suite struct AgentConversationStoreTests {
    @Test func storesDistinctObservationsWithoutReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentConversationStore(directory: dir)
        let pane = UUID()
        try store.note(surface: pane, provider: "codex", sessionID: "thread-1")
        try store.note(surface: pane, provider: "codex", sessionID: "thread-1")
        try store.note(surface: pane, provider: "claude", sessionID: "session_2")
        let entries = try store.entries()
        #expect(entries.count == 2)
        #expect(entries.contains { $0.resumeCommand == "codex resume thread-1" && $0.surface == pane })
        #expect(entries.contains { $0.resumeCommand == "claude --resume session_2" })
        let old = dir.appendingPathComponent("\(pane.uuidString.lowercased()).codex.thread-1")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        #expect(try store.entries().last?.sessionID == "thread-1")
        try store.note(surface: pane, provider: "codex", sessionID: "thread-1")
        #expect(try store.entries().first?.sessionID == "thread-1")
        #expect(throws: (any Error).self) { try store.note(surface: pane, provider: "codex", sessionID: "bad;command") }
    }

    @Test func refusesSymlinkDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = AgentConversationStore(directory: link)
        #expect(throws: (any Error).self) { try store.note(surface: UUID(), provider: "claude", sessionID: "abc") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func refusesASymlinkMasqueradingAsAnObservation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        let path = dir.appendingPathComponent("\(pane.uuidString.lowercased()).codex.thread-1")
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "/dev/null")
        let store = AgentConversationStore(directory: dir)
        #expect(throws: (any Error).self) { try store.note(surface: pane, provider: "codex", sessionID: "thread-1") }
        #expect(try store.entries().isEmpty)
    }
}
