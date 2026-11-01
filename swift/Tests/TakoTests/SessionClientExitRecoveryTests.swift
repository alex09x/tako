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
import Darwin
import Foundation
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct SessionClientExitRecoveryTests {
    @Test func adoptingADisconnectedPlaceholderReleasesOnlyItsOwnerLock() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/tkx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeID = "0.8.1-cc9574e03dfb2480"
        let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let client = surface.pty
        surface.pty = nil
        client?.terminate()
        let record = SessionRecord(id: surface.id, runtimeID: runtimeID, generation: "old",
                                   state: .detached, createdAt: Date())
        try records.write(record)
        let name = SessionNamespace.sessionName(for: surface.id)
        var session: SurfaceSession? = SurfaceSession(runtime: root.appendingPathComponent("unused"),
            namespace: namespace, name: name, owner: try SessionOwnerLock(namespace: namespace, name: name),
            records: records, record: record)
        surface.persistence = session
        session = nil
        let (controller, window) = TerminalTestSupport.makeController(surfaceTree: .init(view: surface))
        defer { surface.persistence?.ended = true; surface.close(); window.close(); _ = controller }
        let candidate = SessionRecoveryInventory.Candidate(id: surface.id, runtimeID: "0.8.1-0000000000000000", identity: .unverified,
            record: record, observedInRuntime: true, observedGeneration: "0123456789abcdef0123456789abcdef",
            processID: nil, executableName: nil)
        #expect(SessionRecoveryPresentation.protectedRuntimes([surface])[surface.id] == runtimeID)
        #expect(SessionRecoveryPresentation.preparePlaceholderForAdoption(candidate))
        #expect(surface.persistence == nil)
        #expect(surface.sessionRetry != nil)
        #expect((try? SessionOwnerLock(namespace: namespace, name: name)) != nil)
        #expect(records.read(surface.id) == .record(record))
    }

    @Test func aDefinitelyExitedShellCanCloseWithoutRemovingItsRecord() async throws {
        let root = URL(fileURLWithPath: "/tmp/tkx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("zmx")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        let runtimeID = "0.8.1-cc9574e03dfb2480"
        let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        let record = SessionRecord(id: id, runtimeID: runtimeID, generation: "g", state: .attached, createdAt: Date())
        try records.write(record)
        let session = SurfaceSession(runtime: runtime, guardedRuntime: runtime, namespace: namespace, name: "abc",
                                     owner: try SessionOwnerLock(namespace: namespace, name: "abc"),
                                     records: records, record: record)
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { session.ended = true; surface.close() }
        let client = surface.pty
        surface.pty = nil
        client?.terminate()
        surface.persistence = session
        session.shellPID = 999_999_999
        session.confirmedLive = true
        var closed = false
        surface.onExit = { _ in closed = true }
        #expect(session.clientExited(surface))
        let deadline = Date().addingTimeInterval(5)
        while !closed && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(closed)
        #expect(!session.confirmedLive)
        guard case .record(let retained) = records.read(id) else { Issue.record("record lost"); return }
        #expect(retained.state == .detached)
    }

    @Test func secureInputDoesNotRecordANewWorkingDirectory() throws {
        let root = URL(fileURLWithPath: "/tmp/tkx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeID = "0.8.1-cc9574e03dfb2480"
        let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { surface.isSecureInputMode = false; surface.close(); window.close() }
        var record = SessionRecord(id: surface.id, runtimeID: runtimeID, generation: "g", state: .attached, createdAt: Date())
        record.workingDirectory = "/safe"
        try records.write(record)
        let session = SurfaceSession(runtime: root.appendingPathComponent("unused"), namespace: namespace,
                                     name: "abc", owner: try SessionOwnerLock(namespace: namespace, name: "abc"),
                                     records: records, record: record)
        defer { session.ended = true }
        surface.persistence = session
        surface.pwd = "/sensitive"
        surface.isSecureInputMode = true
        let snapshots = SessionSnapshotStore(directory: root.appendingPathComponent("snapshots"))
        SessionSnapshotSaver(store: snapshots).save([surface], settings: .init(enabled: true, limit: 4096, secureInput: true))
        guard case .record(let saved) = records.read(surface.id) else { Issue.record("record missing"); return }
        #expect(saved.workingDirectory == "/safe")
    }

    @Test func closingAnUnconnectedPlaceholderDoesNotEndItsSession() throws {
        let root = URL(fileURLWithPath: "/tmp/tkx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeID = "0.8.1-cc9574e03dfb2480"
        let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        let record = SessionRecord(id: id, runtimeID: runtimeID, generation: "g", state: .detached, createdAt: Date())
        try records.write(record)
        let before = Ending.pendingCount
        let previousDetaching = SurfaceSession.appIsDetaching
        SurfaceSession.appIsDetaching = false
        defer { SurfaceSession.appIsDetaching = previousDetaching }
        var session: SurfaceSession? = SurfaceSession(runtime: root.appendingPathComponent("unused"),
            namespace: namespace, name: "abc", owner: try SessionOwnerLock(namespace: namespace, name: "abc"),
            records: records, record: record)
        #expect(session?.confirmedLive == false)
        session = nil
        #expect(Ending.pendingCount == before)
        #expect(records.read(id) == .record(record))
    }

    @Test func sessionPlacementIsSavedWithItsIdentity() throws {
        let root = URL(fileURLWithPath: "/tmp/tkx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeID = "0.8.1-cc9574e03dfb2480"
        let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        let record = SessionRecord(id: id, runtimeID: runtimeID, generation: "g", state: .attached, createdAt: Date())
        try records.write(record)
        let session = SurfaceSession(runtime: root.appendingPathComponent("unused"), namespace: namespace,
                                     name: "abc", owner: try SessionOwnerLock(namespace: namespace, name: "abc"),
                                     records: records, record: record)
        defer { session.ended = true }
        let workspace = UUID()
        session.rememberPlacement(workspaceID: workspace, tabIdentifier: "tab-1", workingDirectory: "/tmp",
                                  windowTabIdentifiers: ["tab-1", "tab-2"])
        guard case .record(let saved) = records.read(id) else { Issue.record("record missing"); return }
        #expect(saved.workspaceID == workspace)
        #expect(saved.tabIdentifier == "tab-1")
        #expect(saved.workingDirectory == "/tmp")
        #expect(saved.windowTabIdentifiers == ["tab-1", "tab-2"])
        #expect(saved.generation == record.generation)
        session.rememberPlacement(workspaceID: nil, tabIdentifier: "tab-1", workingDirectory: nil)
        #expect(records.read(id) == .record(saved))
    }

    @Test func missingRuntimeListingDoesNotEraseSessionRecord() async throws {
        let root = URL(fileURLWithPath: "/tmp/tkx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("zmx")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        let runtimeID = "0.8.1-cc9574e03dfb2480"
        let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        let record = SessionRecord(id: id, runtimeID: runtimeID, generation: "g", state: .attached, createdAt: Date())
        try records.write(record)
        let session = SurfaceSession(runtime: runtime, guardedRuntime: runtime, namespace: namespace, name: "abc",
                                     owner: try SessionOwnerLock(namespace: namespace, name: "abc"),
                                     records: records, record: record)
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { session.ended = true; surface.close() }
        let client = surface.pty
        surface.pty = nil
        client?.terminate()
        surface.persistence = session

        #expect(session.clientExited(surface))
        let deadline = Date().addingTimeInterval(5)
        while surface.sessionRetry == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(surface.sessionRetry != nil)
        #expect(!session.confirmedLive)
        #expect(!session.ended)
        guard case .record(let retained) = records.read(id) else {
            Issue.record("an unlisted session lost its record")
            return
        }
        #expect(retained.state == .detached)
    }
}
