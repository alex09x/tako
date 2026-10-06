/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation
import Testing
@testable import Tako

@Suite
struct SessionSweeperTests {
    private func createTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tako-sweeper-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func sweepRemovesUnownedOrphanSessionFiles() throws {
        let tempHome = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let takoSessions = tempHome.appendingPathComponent(".tako-sessions", isDirectory: true)
        let runtimeDir = takoSessions.appendingPathComponent("0.8.1-testruntime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)

        let sessionName = "11112222333344445555666677778888"
        let ownerPath = runtimeDir.appendingPathComponent("\(sessionName).owner")
        let socketPath = runtimeDir.appendingPathComponent(sessionName)
        try Data().write(to: ownerPath)
        try Data("dummy-socket".utf8).write(to: socketPath)

        #expect(FileManager.default.fileExists(atPath: ownerPath.path))
        #expect(FileManager.default.fileExists(atPath: socketPath.path))

        // Sweep with no active names
        SessionSweeper.sweepOrphans(home: tempHome, activeNames: [])

        #expect(!FileManager.default.fileExists(atPath: ownerPath.path))
        #expect(!FileManager.default.fileExists(atPath: socketPath.path))
    }

    @Test func sweepPreservesActiveSessions() throws {
        let tempHome = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let takoSessions = tempHome.appendingPathComponent(".tako-sessions", isDirectory: true)
        let runtimeDir = takoSessions.appendingPathComponent("0.8.1-testruntime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)

        let sessionName = "aaaabbbbccccddddeeeeffff00001111"
        let ownerPath = runtimeDir.appendingPathComponent("\(sessionName).owner")
        let socketPath = runtimeDir.appendingPathComponent(sessionName)
        try Data().write(to: ownerPath)
        try Data("dummy-socket".utf8).write(to: socketPath)

        // Sweep where sessionName IS in activeNames
        SessionSweeper.sweepOrphans(home: tempHome, activeNames: [sessionName])

        #expect(FileManager.default.fileExists(atPath: ownerPath.path))
        #expect(FileManager.default.fileExists(atPath: socketPath.path))
    }

    @Test func sweepPreservesSessionsWithHeldFlock() throws {
        let tempHome = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let takoSessions = tempHome.appendingPathComponent(".tako-sessions", isDirectory: true)
        let runtimeDir = takoSessions.appendingPathComponent("0.8.1-testruntime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)

        let sessionName = "99998888777766665555444433332222"
        let ownerPath = runtimeDir.appendingPathComponent("\(sessionName).owner")
        let socketPath = runtimeDir.appendingPathComponent(sessionName)
        try Data().write(to: ownerPath)
        try Data("dummy-socket".utf8).write(to: socketPath)

        // Take exclusive flock
        let fd = Darwin.open(ownerPath.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)

        SessionSweeper.sweepOrphans(home: tempHome, activeNames: [])

        #expect(FileManager.default.fileExists(atPath: ownerPath.path))
        #expect(FileManager.default.fileExists(atPath: socketPath.path))

        flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}
