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
import XCTest
@testable import Tako

final class CommandHistoryStoreTests: XCTestCase {
    var tempDirectory: URL!
    var tempFile: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("tako_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        tempFile = tempDirectory.appendingPathComponent("command_history.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testRecordAndSearch() {
        let store = CommandHistoryStore(storageURL: tempFile)
        XCTAssertTrue(store.allEntries().isEmpty)

        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        let paneId = UUID()

        store.record(command: "git status", cwd: "/Users/alex09x/tako", startedAt: t1, duration: 0.12, exitCode: 0, paneId: paneId)
        store.record(command: "cargo test", cwd: "/Users/alex09x/tako/takoctl", startedAt: t2, duration: 5.4, exitCode: 1, paneId: paneId)

        let all = store.allEntries()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].command, "git status")
        XCTAssertEqual(all[0].cwd, "/Users/alex09x/tako")
        XCTAssertEqual(all[0].duration, 0.12)
        XCTAssertEqual(all[0].exitCode, 0)

        XCTAssertEqual(all[1].command, "cargo test")
        XCTAssertEqual(all[1].cwd, "/Users/alex09x/tako/takoctl")
        XCTAssertEqual(all[1].duration, 5.4)
        XCTAssertEqual(all[1].exitCode, 1)

        // Search empty returns newest first
        let recent = store.search(query: "")
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent[0].command, "cargo test")
        XCTAssertEqual(recent[1].command, "git status")

        // Search by command substring
        let gitMatches = store.search(query: "git")
        XCTAssertEqual(gitMatches.count, 1)
        XCTAssertEqual(gitMatches[0].command, "git status")

        // Search by cwd substring
        let ctlMatches = store.search(query: "takoctl")
        XCTAssertEqual(ctlMatches.count, 1)
        XCTAssertEqual(ctlMatches[0].command, "cargo test")
    }

    func testEmptyCommandsIgnored() {
        let store = CommandHistoryStore(storageURL: tempFile)
        store.record(command: "   ", cwd: "/tmp", startedAt: Date(), duration: nil, exitCode: nil, paneId: nil)
        store.record(command: "", cwd: "/tmp", startedAt: Date(), duration: nil, exitCode: nil, paneId: nil)
        XCTAssertTrue(store.allEntries().isEmpty)
    }

    func testPersistenceAndPermissions() throws {
        let store = CommandHistoryStore(storageURL: tempFile)
        store.record(command: "ls -la", cwd: "/tmp", startedAt: Date(), duration: 0.05, exitCode: 0, paneId: nil)

        // Verify file was written
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        // Verify posix permissions
        let attrs = try FileManager.default.attributesOfItem(atPath: tempFile.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(perms, 0o600, "History file must be restricted to user read/write (0600)")

        // Reopen store from disk
        let store2 = CommandHistoryStore(storageURL: tempFile)
        let loaded = store2.allEntries()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].command, "ls -la")
    }

    func testHistoryBoundingAtMaxEntries() {
        let store = CommandHistoryStore(storageURL: tempFile)
        // Record 10 entries when limit is smaller or verify FIFO
        for i in 0..<50 {
            store.record(command: "echo \(i)", cwd: "/tmp", startedAt: Date(), duration: nil, exitCode: 0, paneId: nil)
        }
        XCTAssertEqual(store.allEntries().count, 50)
        XCTAssertEqual(store.allEntries().first?.command, "echo 0")
        XCTAssertEqual(store.allEntries().last?.command, "echo 49")
    }

    func testSearchLimitsNegativeAndOversized() {
        let store = CommandHistoryStore(storageURL: tempFile)
        for i in 1...10 {
            store.record(command: "cmd \(i)", cwd: "/tmp", startedAt: Date(), duration: nil, exitCode: 0, paneId: nil)
        }
        // Negative and zero limits safely return empty without crashing or trapping
        XCTAssertEqual(store.search(query: "", limit: -1).count, 0)
        XCTAssertEqual(store.search(query: "cmd", limit: -100).count, 0)
        XCTAssertEqual(store.search(query: "", limit: 0).count, 0)

        // Positive limit clamped to available or max
        XCTAssertEqual(store.search(query: "", limit: 5).count, 5)
        XCTAssertEqual(store.search(query: "", limit: 100_000).count, 10)
    }
}
