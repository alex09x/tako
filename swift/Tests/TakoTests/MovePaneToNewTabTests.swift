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

    private func unread(_ surface: Tako.SurfaceView, _ tag: String) {
        NotificationStore.shared.addNotification(id: "move-\(tag)-\(surface.id)", surfaceId: surface.id,
                                                 paneTitle: tag, title: "done", body: "")
    }

    @Test func withNoSelectThePaneInItsNewTabStaysUnread() throws {
        let previousSystem = TerminalController.system
        TerminalController.system = TerminalTestSupport.injectedWindowSystem()
        defer { TerminalController.system = previousSystem }
        let source = try tab(split: true)
        let moving = source.panes[1], staying = source.panes[0]
        source.controller.focusedSurface = staying
        unread(moving, "newtab")
        defer { NotificationStore.shared.markRead(surfaceId: moving.id) }
        let workspace = WorkspaceStore.shared.activeWorkspaceId
        let (pty, pid) = try live(moving)
        defer { pty.terminate() }

        let created = try source.controller.movePaneToNewTab(moving, select: false)
        defer { close(source.window, created.window ?? source.window) }
        #expect(NotificationStore.shared.unreadCount(for: moving.id) == 1, "loading the new tab is not looking at it")
        #expect(created.focusedSurface === moving, "its logical focus")
        #expect(Tako.CustomTabGroup.group(for: source.window).selectedWindow === source.window)
        #expect(WorkspaceStore.shared.activeWorkspaceId == workspace)
        #expect(moving.pty === pty && pty.alive && moving.pid == pid)
    }

    @Test func aSessionMergeLeavesThePanesItPassesOverUnread() throws {
        let previousFront = MovePaneFront.isInFront
        defer { MovePaneFront.isInFront = previousFront }
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source.window, destination.window) }
        sameWorkspace(source, destination)
        _ = try #require(source.controller.newSplit(at: source.panes[1], direction: .right))
        _ = try #require(source.controller.newSplit(at: source.panes[0], direction: .down))
        let panes = source.panes
        let first = panes[0], last = try #require(panes.last)
        source.controller.focusedSurface = first
        // The pane the focus passes to when the first leaves: shown on the
        // way only if the merge hands focus over between its steps.
        let node = try #require(source.controller.surfaceTree.root?.node(view: first))
        let passed = try #require(source.controller.findNextFocusTargetAfterClosing(node: node))
        try #require(passed !== last, "the focus must pass over a pane that is not the last one")
        // The source is the tab the user is looking at.
        MovePaneFront.isInFront = { $0 === source.window }
        unread(passed, "passed")
        defer { NotificationStore.shared.markRead(surfaceId: passed.id) }
        let ptys = try panes.map(live)
        defer { ptys.forEach { $0.pty.terminate() } }
        let anchor = try #require(destination.panes.first)

        try MovePaneToTab.mergeTab(source.controller, into: destination.controller)
        #expect(destination.panes.map(\.id) == [anchor.id] + panes.map(\.id))
        #expect(NotificationStore.shared.unreadCount(for: passed.id) == 1, "passed over on the way, never shown")
        #expect(destination.controller.focusedSurface === last, "only the last pane is focused")
        #expect(zip(panes, ptys).allSatisfy { $0.pty === $1.pty && $0.pid == $1.pid && $1.pty.alive })
        #expect(!TerminalController.all.contains { $0 === source.controller })
    }

    @Test func aRefusedMergeSaysHowFarItGotAndIsSaidWhereTheUserIs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Appearance.json")
        let styles = ScopedAppearanceStore(fileURL: file)
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source.window, destination.window) }
        sameWorkspace(source, destination)
        // Laid out before the move, as a window the user acts in is: a test
        // window's first layout otherwise falls in the display cycle right
        // after a no-select move, and SwiftUI crashed the host there (signal
        // 11/6 in TabBarController.install's isMovable KVO, mid-render).
        for tab in [source, destination] { tab.window.contentView?.layoutSubtreeIfNeeded() }
        let (a, b) = (source.panes[0], source.panes[1])
        // The first pane has its own preset, so it carries nothing; the
        // second must carry the session's look, which can no longer be written.
        try styles.setValue("Anything", for: "theme", scope: .pane(a.id))
        try styles.setValue("#010101", for: "background", scope: .session(source.window.stableTabIdentifier))
        try "{\"version\": 2, \"sessions\": {}}".write(to: file, atomically: true, encoding: .utf8)  // edited outside Tako

        var message = ""
        do {
            try MovePaneToTab.mergeTab(source.controller, into: destination.controller, select: false, appearance: styles)
            Issue.record("the merge should have been refused")
        } catch { message = String(describing: error) }
        #expect(message.contains("1 of 2 panes moved") && message.contains("the other 1 stay"), "\(message)")
        #expect(destination.panes.contains(a) && source.panes == [b])
        #expect(TerminalController.all.contains { $0 === source.controller }, "the source keeps what did not move")

        // Said in the window the action came from while it is on screen, not
        // in the pane's own, which may be hidden or emptied.
        // Here the destination's window stands for the one the sidebar click came from.
        let initiating = destination.window
        let shown: (NSWindow) -> Bool = { $0 === initiating }
        #expect(MovePaneToTab.presenter(for: b, from: initiating, onScreen: { _ in false }) === source.window,
                "an initiator off screen is passed over")
        #expect(MovePaneToTab.presenter(for: b, from: initiating, onScreen: shown) === initiating)
        #expect(MovePaneToTab.presenter(for: b, from: nil, onScreen: shown) === source.window, "else the pane's own")
    }
}
