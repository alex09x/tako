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

@MainActor
struct WorkspaceRecoveryArchiveTests {
    @Test func workspaceHistoryDoesNotFollowASymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")
        _ = WorkspaceStore(storeURL: url)
        let original = try Data(contentsOf: url)
        let elsewhere = dir.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("History"), withDestinationURL: elsewhere)
        let reopened = WorkspaceStore(storeURL: url)
        #expect(!reopened.persistenceAvailable)
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func failedWorkspaceWriteStopsFurtherWritesAndNotifies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(storeURL: url)
        let original = try Data(contentsOf: url)
        var notices = 0
        let token = NotificationCenter.default.addObserver(forName: .takoWorkspacePersistenceFailed, object: store, queue: nil) { _ in
            notices += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        chmod(dir.path, 0o500)
        _ = store.createWorkspace(name: "Cannot Persist")
        #expect(!store.persistenceAvailable)
        #expect(notices == 1)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func thePreviousWorkspaceFileSurvivesLaterChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")
        let first = WorkspaceStore(storeURL: url)
        _ = first.createWorkspace(name: "Previous")
        let original = try Data(contentsOf: url)
        let next = WorkspaceStore(storeURL: url)
        #expect(next.persistenceAvailable)
        _ = next.createWorkspace(name: "New")
        #expect(try Data(contentsOf: url) != original)
        let history = dir.appendingPathComponent("History")
        let files = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
        #expect(try files.contains { try Data(contentsOf: $0) == original })
    }

    @Test(arguments: [false, true])
    func archiveFailureNeverOverwritesTheOriginal(corrupt: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")
        let first = WorkspaceStore(storeURL: url)
        _ = first.createWorkspace(name: "Previous")
        if corrupt { try Data("broken workspace data".utf8).write(to: url) }
        let original = try Data(contentsOf: url)
        try Data("not a directory".utf8).write(to: dir.appendingPathComponent("History"))
        let next = WorkspaceStore(storeURL: url)
        #expect(!next.persistenceAvailable)
        _ = next.createWorkspace(name: "Must Not Persist")
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func corruptWorkspaceBytesAreArchivedBeforeFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")
        let corrupt = Data("broken workspace data".utf8)
        try corrupt.write(to: url)
        let store = WorkspaceStore(storeURL: url)
        #expect(!store.persistenceAvailable)
        #expect(try Data(contentsOf: url) == corrupt)
        let files = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("History"),
                                                                 includingPropertiesForKeys: nil)
        #expect(try files.contains { try Data(contentsOf: $0) == corrupt })
    }
}
