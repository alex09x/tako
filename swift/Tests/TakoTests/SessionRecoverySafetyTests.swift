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
import Testing
@testable import Tako

@MainActor
@Suite(.serialized)
struct SessionRecoverySafetyTests {
    @Test func layoutCaptureKeepsEachSessionsPhysicalTabGroup() throws {
        let root = URL(fileURLWithPath: "/tmp/tkg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore.shared
        store.resetForTesting()
        let one = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let two = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let (first, firstWindow) = TerminalTestSupport.makeController(surfaceTree: .init(view: one))
        let (second, secondWindow) = TerminalTestSupport.makeController(surfaceTree: .init(view: two))
        let ns = try SessionNamespace.open(runtimeID: "0.8.1-0000000000000000", home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let record = SessionRecord(id: one.id, runtimeID: ns.runtimeID, generation: "generation", state: .attached, createdAt: Date())
        try records.write(record)
        let name = SessionNamespace.sessionName(for: one.id)
        let session = SurfaceSession(runtime: root.appendingPathComponent("unused"), namespace: ns, name: name,
                                     owner: try SessionOwnerLock(namespace: ns, name: name), records: records, record: record)
        one.persistence = session
        defer {
            session.ended = true
            Tako.CustomTabGroup.close(firstWindow); Tako.CustomTabGroup.close(secondWindow)
            firstWindow.close(); secondWindow.close(); one.close(); two.close(); store.resetForTesting()
        }
        Tako.CustomTabGroup.join(secondWindow, to: firstWindow, select: false)
        firstWindow.contentView = one
        let saver = SessionSnapshotSaver(store: SessionSnapshotStore(directory: root.appendingPathComponent("snapshots")))
        saver.save([one], settings: .init(enabled: false, limit: 4096, secureInput: false))
        guard case .record(let fromSaver) = records.read(one.id) else { Issue.record("record disappeared"); return }
        #expect(fromSaver.windowTabIdentifiers == [firstWindow.stableTabIdentifier, secondWindow.stableTabIdentifier])
        var cleared = session.record
        cleared.windowTabIdentifiers = nil
        try records.write(cleared)
        session.record = cleared
        _ = LayoutRecorder.capture(controllers: [first, second])
        guard case .record(let saved) = records.read(one.id) else { Issue.record("record disappeared"); return }
        #expect(saved.windowTabIdentifiers == [firstWindow.stableTabIdentifier, secondWindow.stableTabIdentifier])
    }

    @Test func normalQuitKeepsWorkspaceTabAssociation() {
        let wasSuppressed = Tako.CustomTabGroup.suppressWindowOrderingForTesting
        let wasDetaching = SurfaceSession.appIsDetaching
        Tako.CustomTabGroup.suppressWindowOrderingForTesting = true
        let store = WorkspaceStore.shared
        store.resetForTesting()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            SurfaceSession.appIsDetaching = wasDetaching
            window.close(); store.resetForTesting()
            Tako.CustomTabGroup.suppressWindowOrderingForTesting = wasSuppressed
        }
        _ = Tako.CustomTabGroup.group(for: window)
        let id = window.stableTabIdentifier
        store.assignTab(tabIdentifier: id, to: WorkspaceStore.defaultWorkspaceId)
        SurfaceSession.appIsDetaching = true
        Tako.CustomTabGroup.close(window)
        #expect(store.workspace(forTab: id)?.id == WorkspaceStore.defaultWorkspaceId)
    }

    @Test func layoutIncludesTabsHiddenInOtherWorkspaces() {
        let wasSuppressed = Tako.CustomTabGroup.suppressWindowOrderingForTesting
        Tako.CustomTabGroup.suppressWindowOrderingForTesting = true
        let store = WorkspaceStore.shared
        store.resetForTesting()
        let firstSurface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let secondSurface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let (first, firstWindow) = TerminalTestSupport.makeController(surfaceTree: .init(view: firstSurface))
        let (second, secondWindow) = TerminalTestSupport.makeController(surfaceTree: .init(view: secondSurface))
        defer {
            Tako.CustomTabGroup.close(firstWindow); Tako.CustomTabGroup.close(secondWindow)
            firstWindow.close(); secondWindow.close(); firstSurface.close(); secondSurface.close()
            store.resetForTesting()
            Tako.CustomTabGroup.suppressWindowOrderingForTesting = wasSuppressed
        }
        let hidden = store.createWorkspace(name: "Hidden")
        Tako.CustomTabGroup.join(secondWindow, to: firstWindow, select: false)
        store.assignTab(tabIdentifier: firstWindow.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)
        store.assignTab(tabIdentifier: secondWindow.stableTabIdentifier, to: hidden.id)
        let group = Tako.CustomTabGroup.group(for: firstWindow)
        #expect(group.visibleWindows.count == 1)
        let journal = LayoutRecorder.capture(controllers: [first, second])
        #expect(journal.windows.count == 1)
        #expect(journal.windows.first?.tabs.count == 2)
    }
}
