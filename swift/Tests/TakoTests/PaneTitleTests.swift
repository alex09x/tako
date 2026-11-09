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

/// A pane's own name (“Rename…” in its header menu): kept by its
/// stable UUID across launches, shown in the header, the shelf, the sidebar
/// and accessibility, never written over the program's title, its
/// neighbours or its session; removing it shows the program's title again.
@Suite(.serialized) @MainActor
struct PaneTitleTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pane-titles-\(UUID().uuidString)/PaneTitles.json")
    }

    @Test func aNameIsKeptAcrossLaunchesAndAnEmptyOneRemovesIt() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pane = UUID(), other = UUID()
        let first = PaneTitleStore(fileURL: url)
        #expect(first.title(for: pane) == nil, "a store without a file names a pane")
        first.setTitle("  build\nlogs  ", for: pane)
        #expect(first.title(for: pane) == "build logs")

        let relaunched = PaneTitleStore(fileURL: url)
        #expect(relaunched.title(for: pane) == "build logs" && relaunched.title(for: other) == nil)
        relaunched.setTitle(String(repeating: "x", count: 500), for: other)
        #expect(relaunched.title(for: other)?.count == PaneTitleStore.maxLength)
        relaunched.setTitle("   ", for: pane)
        #expect(PaneTitleStore(fileURL: url).title(for: pane) == nil, "an empty name was kept")
    }

    @Test func anUnreadableFileNamesNoPaneAndIsNotLost() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        let store = PaneTitleStore(fileURL: url)
        #expect(store.titles.isEmpty && store.loadError != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json", "loading rewrote the file")

        // A rename does not replace the unreadable file with a new one.
        let pane = UUID()
        let failure = store.setTitle("логи", for: pane)
        guard case .unreadableFile = failure else { Issue.record("rename over an unreadable file: \(String(describing: failure))"); return }
        #expect(store.title(for: pane) == nil, "the name shows although it was not saved")
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json", "the unreadable file was overwritten")
    }

    @Test func aFailedWriteKeepsTheOldNameInMemoryAndOnDisk() throws {
        let url = file()
        let dir = url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = PaneTitleStore(fileURL: url)
        let pane = UUID()
        #expect(store.setTitle("старое", for: pane) == nil)
        let before = try Data(contentsOf: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let failure = store.setTitle("новое", for: pane)
        guard case .writeFailed = failure else { Issue.record("a write into a read-only folder succeeded: \(String(describing: failure))"); return }
        #expect(failure?.localizedDescription.hasPrefix("Could not save the name:") == true)
        #expect(store.title(for: pane) == "старое", "memory shows a name that was not saved")
        #expect(try Data(contentsOf: url) == before, "the file changed")
        #expect(PaneTitleStore(fileURL: url).title(for: pane) == "старое")
    }

    @Test func theNameShowsOverTheProgramTitleOfThatPaneOnly() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setContentSize(NSSize(width: 1000 + SessionSidebarWidth.current(), height: 700))
        controller.showWindow(nil)
        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        defer { PaneTitleStore.shared.setTitle(nil, for: p2.id) }
        let programTitle = p2.title, windowTitle = window.title, neighbour = FloatingPaneGeometry.shortTitle(for: p1)

        PaneTitleStore.shared.setTitle("логи сборки", for: p2.id)
        #expect(FloatingPaneGeometry.shortTitle(for: p2) == "логи сборки")
        #expect(p2.title == programTitle, "the program's title was overwritten")
        #expect(FloatingPaneGeometry.shortTitle(for: p1) == neighbour, "the neighbour was renamed")
        #expect(window.title == windowTitle, "the session was renamed")

        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        func header(_ v: NSView) -> NSView? {
            if v.accessibilityIdentifier() == "FloatingPaneHeader-\(p2.id.uuidString.lowercased())" { return v }
            for s in v.subviews { if let hit = header(s) { return hit } }
            return nil
        }
        let label = try #require(header(content)).accessibilityLabel() ?? ""
        #expect(label.hasPrefix("логи сборки"), "the header's AX label is \(label)")

        let sidebar = SessionSidebarStore(defaults: UserDefaults(suiteName: "test.panetitle.\(UUID())")!)
        let rows = sidebar.workspaceGroups(for: window, workspaceStore: .shared).flatMap(\.items)
        #expect(rows.first { $0.isChild && $0.surfaceId == p2.id }?.title == "логи сборки", "sidebar rows: \(rows.map(\.title))")
        #expect(rows.first { $0.isChild && $0.surfaceId == p1.id }?.title != "логи сборки")

        PaneTitleStore.shared.setTitle("", for: p2.id)
        #expect(FloatingPaneGeometry.shortTitle(for: p2) != "логи сборки", "the name stayed after it was removed")
    }

    @Test func theMenuStartsWithRename() {
        _ = NSApplication.shared
        var renamed = 0
        let menu = FloatingPaneMenu(mode: .normal, isTiled: true, split: { _ in }, toggleMaximize: {}, toggleFloating: {},
                                    minimize: {}, close: {}, rename: { renamed += 1 })
        let item = menu.items().first
        #expect(item?.identifier?.rawValue == "FloatingPaneMenuRename" && item?.title == "Rename…")
        if let item, let action = item.action { _ = (item.target as? NSObject)?.perform(action, with: item) }
        #expect(renamed == 1)
    }
}
