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

@Suite(.serialized)
@MainActor
struct SessionMissingRecordTests {
    @Test(arguments: [0, 1, 2])
    func recoveryFailureShowsSavedScreenAndReason(kind: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = SessionSnapshotStore.shared
        SessionSnapshotStore.shared = SessionSnapshotStore(directory: root.appendingPathComponent("Snapshots"))
        defer { SessionSnapshotStore.shared = previous; try? FileManager.default.removeItem(at: root) }
        let source = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        defer { source.close(); surface.close() }
        source.core.feed(bytes: Data("saved-screen-marker".utf8))
        let snapshot = SessionSnapshot(savedAt: Date(), checkpoint: try source.core.checkpointExport(flags: 0, maxBytes: 1_000_000))
        let records = SessionPlaces.records
        if kind == 1 {
            try FileManager.default.createDirectory(at: records.directory, withIntermediateDirectories: true)
            try Data("damaged".utf8).write(to: records.url(for: surface.id))
        } else if kind == 2 {
            try records.write(SessionRecord(id: surface.id, runtimeID: "0.8.1-0000000000000000",
                                            generation: "gen", state: .detached, createdAt: Date()))
        }
        surface.launchPersistentSession(workingDir: nil, snapshot: snapshot, restored: true, hadPersistentSession: true)
        let text = surface.core.bufferText()
        #expect(text.contains("saved-screen-marker"))
        #expect(text.contains(kind == 0 ? "record is gone" : kind == 1 ? "cannot be read" : "cannot be reached"))
    }

    @Test(arguments: [false, true])
    func anOlderLayoutWithoutPersistentFlagDoesNotReplaceItsRecord(corrupt: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = SessionSnapshotStore.shared
        SessionSnapshotStore.shared = SessionSnapshotStore(directory: root.appendingPathComponent("Snapshots"))
        defer {
            SessionSnapshotStore.shared = previous
            try? FileManager.default.removeItem(at: root)
        }
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { surface.close() }
        let records = SessionPlaces.records
        let record = SessionRecord(id: surface.id, runtimeID: "0.8.1-cc9574e03dfb2480",
                                   generation: "gen1", state: .detached, createdAt: Date())
        try records.write(record)
        if corrupt { try Data("damaged".utf8).write(to: records.url(for: surface.id)) }
        let before = try Data(contentsOf: records.url(for: surface.id))
        let originalPTY = surface.pty
        surface.launchPersistentSession(workingDir: nil, snapshot: nil, restored: true, hadPersistentSession: false)
        #expect(surface.hadPersistentSession)
        #expect(surface.pty === originalPTY)
        #expect(surface.sessionRetry != nil)
        #expect(try Data(contentsOf: records.url(for: surface.id)) == before)
    }

    @Test func persistentPaneNeverOffersOrRunsAnAutomaticResumeCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResumeSessionStore(directory: root)
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { surface.dismissResumeBanner(); surface.close() }
        store.set(record: ResumeSessionRecord(argv: ["echo", "resume"], cwd: "/tmp", isImported: true), for: surface.id)
        surface.hadPersistentSession = true
        surface.checkAndApplyResumeOnRestore(restoredDir: nil, store: store)
        #expect(surface.resumeBannerHostingView == nil)
        surface.hadPersistentSession = false
        surface.checkAndApplyResumeOnRestore(restoredDir: nil, store: store)
        #expect(surface.resumeBannerHostingView != nil)
    }

    @Test func missingRuntimeDoesNotStartAnUnprotectedReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = SessionSnapshotStore.shared
        SessionSnapshotStore.shared = SessionSnapshotStore(directory: root.appendingPathComponent("Snapshots"))
        defer {
            SessionSnapshotStore.shared = previous
            try? FileManager.default.removeItem(at: root)
        }
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { surface.close() }
        let originalPTY = surface.pty
        surface.launchPersistentSession(workingDir: nil, snapshot: nil, restored: false, hadPersistentSession: false)
        #expect(surface.pty === originalPTY)
        #expect(surface.sessionRetry != nil)
        #expect(surface.core.bufferText().contains("runtime is unavailable"))
    }

    @Test func disconnectedPlaceholderCanBeDiscoveredForRecovery() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { surface.close() }
        let client = surface.pty
        surface.pty = nil
        client?.terminate()
        surface.sessionRetry = {}
        #expect(!SessionRecoveryPresentation.protectedSurfaceIDs([surface]).contains(surface.id))
        surface.sessionRetry = nil
        #expect(SessionRecoveryPresentation.protectedSurfaceIDs([surface]).contains(surface.id))
    }

    @Test func retryDoesNotCreateAReplacementSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = SessionSnapshotStore.shared
        SessionSnapshotStore.shared = SessionSnapshotStore(directory: root.appendingPathComponent("Snapshots"))
        defer {
            SessionSnapshotStore.shared = previous
            try? FileManager.default.removeItem(at: root)
        }
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { surface.close() }
        let originalPTY = surface.pty
        surface.launchPersistentSession(workingDir: nil, snapshot: nil, restored: true, hadPersistentSession: true)
        #expect(surface.pty === originalPTY)
        #expect(surface.sessionRetry != nil)
        surface.sessionRetry?()
        #expect(surface.pty === originalPTY)
        #expect(surface.sessionRetry != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SessionRecords").path))
    }
}
