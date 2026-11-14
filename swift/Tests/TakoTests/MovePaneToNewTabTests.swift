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

/// «Move to Tab ▸ New Tab» takes one pane out of a split into a tab of its
/// own, the same live process; a session row's «Move to Tab» merges its
/// whole tab into another; the pane header's button offers the same menu.
@MainActor @Suite(.serialized)
struct MovePaneToNewTabTests {
    @MainActor struct Tab {
        let controller: TerminalController
        let window: NSWindow
        var panes: [Tako.SurfaceView] { Array(controller.surfaceTree) }
    }

    private func tab(split: Bool) throws -> Tab {
        let (controller, window) = TerminalTestSupport.loaded()
        window.setContentSize(NSSize(width: 1200, height: 700))
        controller.floatingCanvas.reduceMotionProvider = { true }
        if split {
            let a = try #require(controller.focusedSurface)
            _ = try #require(controller.newSplit(at: a, direction: .right))
        }
        return Tab(controller: controller, window: window)
    }

    private func close(_ windows: NSWindow...) {
        for window in windows {
            window.close()
            if let controller = window.windowController as? TerminalController {
                TerminalTestSupport.tearDown(controller, window)
            }
        }
    }

    private func live(_ surface: Tako.SurfaceView) throws -> (pty: PTY, pid: Int) {
        surface.pty = PTY(cols: 80, rows: 24, workingDirectory: NSTemporaryDirectory(), program: ["/bin/sleep", "60"])
        let pty = try #require(surface.pty)
        #expect(pty.alive && surface.pid > 0)
        return (pty, surface.pid)
    }

    private func owners(of surface: Tako.SurfaceView) -> [TerminalController] {
        TerminalController.all.filter { $0.surfaceTree.contains(surface) }
    }

    private func sameWorkspace(_ tabs: Tab...) {
        guard let first = tabs.first,
              let workspace = WorkspaceStore.shared.workspace(forTab: first.window.stableTabIdentifier) else { return }
        for tab in tabs.dropFirst() {
            WorkspaceStore.shared.assignTab(tabIdentifier: tab.window.stableTabIdentifier, to: workspace.id)
        }
    }

    @Test func aPaneLeavesItsSplitForANewTabRightAfterItWithTheSameProcess() throws {
        let previousSystem = TerminalController.system
        TerminalController.system = TerminalTestSupport.injectedWindowSystem()
        defer { TerminalController.system = previousSystem }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-newtab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let styles = ScopedAppearanceStore(fileURL: dir.appendingPathComponent("Appearance.json"))
        let here = workspaces.createWorkspace(name: "Here")
        let source = try tab(split: true), after = try tab(split: false)
        Tako.CustomTabGroup.join(after.window, to: source.window, select: false)
        Tako.CustomTabGroup.group(for: source.window).select(source.window)
        workspaces.assignTab(tabIdentifier: source.window.stableTabIdentifier, to: here.id)
        let moving = source.panes[1], staying = source.panes[0]
        source.controller.focusedSurface = moving
        let (pty, pid) = try live(moving)
        defer { pty.terminate() }

        let created = try source.controller.movePaneToNewTab(moving, select: false, appearance: styles, workspaces: workspaces)
        let window = try #require(created.window)
        defer { close(source.window, after.window, window) }
        #expect(Array(created.surfaceTree) == [moving], "alone in the new tab")
        #expect(moving.pty === pty && pty.alive && moving.pid == pid, "the same running process")
        #expect(source.panes.map(\.id) == [staying.id])
        #expect(owners(of: moving).map(ObjectIdentifier.init) == [ObjectIdentifier(created)])
        let group = Tako.CustomTabGroup.group(for: source.window)
        #expect(group.windows.firstIndex(of: window) == group.windows.firstIndex(of: source.window).map { $0 + 1 },
                "right after the tab it left")
        #expect(group.selectedWindow === source.window, "select: false changes no selection")
        #expect(workspaces.workspace(forTab: window.stableTabIdentifier)?.id == here.id, "in the same workspace")
        #expect(source.controller.focusedSurface === staying)
    }

    @Test func aLonePaneAlreadyIsATabAndIsNotMoved() throws {
        let lone = try tab(split: false)
        defer { close(lone.window) }
        let pane = try #require(lone.panes.first)
        let windows = TerminalController.all.count
        #expect(throws: MovePaneError.self) { try lone.controller.movePaneToNewTab(pane, select: false) }
        #expect(lone.panes == [pane])
        #expect(TerminalController.all.count == windows)
        #expect(MovePaneToTab.splitTab(of: pane) == nil)
    }

    @Test func aSessionMergesAllItsPanesIntoAnotherTabAndCloses() throws {
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source.window, destination.window) }
        sameWorkspace(source, destination)
        let (a, b) = (source.panes[0], source.panes[1])
        let anchor = try #require(destination.panes.first)
        destination.controller.focusedSurface = anchor
        let (ptyA, pidA) = try live(a), (ptyB, pidB) = try live(b)
        defer { ptyA.terminate(); ptyB.terminate() }

        let row = try #require(MovePaneToTab.subject(tabID: source.window.stableTabIdentifier, surfaceID: nil, isChild: false))
        #expect(row.pane == nil && row.tab === source.controller)
        #expect(MovePaneToTab.destinations(for: row).contains { $0 === destination.controller })
        #expect(!MovePaneToTab.canLeave(row), "a session row has no «New Tab»")
        try MovePaneToTab.move(row, into: destination.controller)
        #expect(destination.panes.map(\.id) == [anchor.id, a.id, b.id], "in order, right of the focused pane")
        #expect(a.pty === ptyA && a.pid == pidA && b.pty === ptyB && b.pid == pidB && ptyA.alive && ptyB.alive)
        #expect(!TerminalController.all.contains { $0 === source.controller }, "the emptied tab closed")
        #expect(throws: MovePaneError.self) { try MovePaneToTab.mergeTab(destination.controller, into: destination.controller) }
    }

    @Test func aTerminalRowMovesOnlyItsPaneAndOffersANewTab() throws {
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source.window, destination.window) }
        sameWorkspace(source, destination)
        let (moving, staying) = (source.panes[1], source.panes[0])
        let row = try #require(MovePaneToTab.subject(tabID: source.window.stableTabIdentifier,
                                                     surfaceID: moving.id, isChild: true))
        #expect(row.pane === moving && MovePaneToTab.canLeave(row))
        #expect(MovePaneToTab.subject(tabID: source.window.stableTabIdentifier, surfaceID: UUID(), isChild: true) == nil)
        try MovePaneToTab.move(row, into: destination.controller)
        #expect(destination.panes.contains(moving) && source.panes == [staying])
        #expect(TerminalController.all.contains { $0 === source.controller }, "a tab with panes left stays")
    }

    @Test func theHeaderMenuOffersNewTabOnlyForASplitPaneAndSaysWhenThereIsNowhereToGo() throws {
        let split = try tab(split: true), lone = try tab(split: false)
        defer { close(split.window, lone.window) }
        let workspaces = WorkspaceStore.shared
        let other = workspaces.createWorkspace(name: "Elsewhere-\(UUID().uuidString.prefix(6))")
        defer { _ = workspaces.deleteWorkspace(id: other.id) }
        workspaces.assignTab(tabIdentifier: lone.window.stableTabIdentifier, to: other.id)
        let pane = try #require(lone.panes.first)
        #expect(MovePaneToTab.destinations(for: pane).isEmpty, "alone in its workspace")

        let item = MovePaneToTab.menuItem(for: split.panes[1])
        #expect(item.isEnabled)
        #expect(item.submenu?.items.contains { $0.identifier?.rawValue == "PaneMenuMoveToNewTab" } == true)
        #expect(!MovePaneToTab.menuItem(for: pane).isEnabled, "a lone pane with no other tab has nowhere to go")
        let empty = MovePaneToTab.buttonMenu(for: pane)
        #expect(empty.items.count == 1 && empty.items.first?.isEnabled == false)
    }
}
