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

/// `takoctl pane move --into` and the pane menu's «Move to Tab»: a pane
/// joins another tab beside a pane there, the same live view and process; a
/// tab it leaves empty closes, one it leaves with panes stays. A move into
/// another tab is not undoable and leaves no undo that could lose the pane;
/// `--no-select` changes no selection, workspace or focus elsewhere; the
/// pane keeps its look.
@MainActor @Suite(.serialized)
struct ControlPaneMoveIntoTabTests {
    @MainActor struct Tab {
        let controller: TerminalController
        let window: NSWindow
        var panes: [Tako.SurfaceView] { Array(controller.surfaceTree) }
    }

    /// A window whose undo manager is the given one, as AppDelegate's is for every real window.
    final class UndoWindow: TerminalWindow {
        var manager: UndoManager?
        override var undoManager: UndoManager? { manager }
    }

    private func tab(split: Bool, undo: ExpiringUndoManager? = nil) throws -> Tab {
        let controller: TerminalController, window: NSWindow
        if let undo {
            TerminalTestSupport.preventQuitting()
            controller = TerminalController(Tako.App(), withBaseConfig: nil, withSurfaceTree: nil)
            let own = UndoWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            own.isReleasedWhenClosed = false
            own.manager = undo
            controller.window = own
            controller.windowDidLoad()
            window = own
        } else {
            (controller, window) = { let pair = TerminalTestSupport.loaded(); return (pair.controller, pair.window) }()
        }
        window.setContentSize(NSSize(width: 1200, height: 700))
        controller.floatingCanvas.reduceMotionProvider = { true }
        if split {
            let a = try #require(controller.focusedSurface)
            _ = try #require(controller.newSplit(at: a, direction: .right))
        }
        return Tab(controller: controller, window: window)
    }

    private func close(_ tabs: Tab...) {
        for tab in tabs {
            tab.window.close()
            TerminalTestSupport.tearDown(tab.controller, tab.window)
        }
    }

    private func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-move-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func move(_ surface: Tako.SurfaceView, into anchor: Tako.SurfaceView, tabs: [Tab],
                      _ extra: [String: JSON] = [:]) -> ControlResponse {
        let previous = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = previous }
        var args: [String: JSON] = ["action": .string("move"), "target": .string(surface.id.uuidString),
                                    "into": .string(anchor.id.uuidString), "select": .bool(false)]
        args.merge(extra) { _, new in new }
        let all = tabs.flatMap { tab in
            tab.panes.map { ControlCommands.Pane(surface: $0, windowID: "w", tabID: "t", controller: tab.controller) }
        }
        return ControlCommands.handle(ControlRequest(cmd: "pane", args: args), all: all)
    }

    private func failure(_ response: ControlResponse) -> String? {
        if case .failure(let error) = response { return error.message }
        return nil
    }

    /// A running process of its own, as ControlWindowTests gives a pane; the caller terminates it.
    private func live(_ surface: Tako.SurfaceView) throws -> (pty: PTY, pid: Int) {
        surface.pty = PTY(cols: 80, rows: 24, workingDirectory: NSTemporaryDirectory(), program: ["/bin/sleep", "60"])
        let pty = try #require(surface.pty)
        #expect(pty.alive && surface.pid > 0)
        return (pty, surface.pid)
    }

    private func owners(of surface: Tako.SurfaceView) -> [TerminalController] {
        TerminalController.all.filter { $0.surfaceTree.contains(surface) }
    }

    @Test func withNoSelectAPaneJoinsAnInactiveTabAndNothingElseChanges() throws {
        let source = try tab(split: true), destination = try tab(split: false), third = try tab(split: false)
        defer { close(source, destination, third) }
        Tako.CustomTabGroup.join(source.window, to: third.window, select: false)
        Tako.CustomTabGroup.join(destination.window, to: third.window, select: false)
        let group = Tako.CustomTabGroup.group(for: third.window)
        group.select(third.window)
        let moving = source.panes[1], staying = source.panes[0]
        source.controller.focusedSurface = moving
        let anchor = try #require(destination.panes.first)
        destination.controller.focusedSurface = anchor
        let thirdFocus = third.controller.focusedSurface
        let activeWorkspace = WorkspaceStore.shared.activeWorkspaceId
        let (pty, pid) = try live(moving)
        defer { pty.terminate() }

        guard case .ok(let result) = move(moving, into: anchor, tabs: [source, destination, third], ["split": .string("down")]) else {
            Issue.record("pane move --into failed")
            return
        }
        #expect(result["id"]?.string == moving.id.uuidString.lowercased())
        #expect(result["into"]?.string == anchor.id.uuidString.lowercased())
        #expect(destination.panes.map(\.id) == [anchor.id, moving.id], "below the anchor, in its tab")
        #expect(moving.pty === pty && pty.alive && moving.pid == pid, "the same running process")
        #expect(source.panes.map(\.id) == [staying.id])
        #expect(owners(of: moving).count == 1)
        #expect(TerminalController.all.contains { $0 === source.controller }, "a tab with panes left stays open")
        #expect(group.selectedWindow === third.window, "the selected tab stays selected")
        #expect(third.controller.focusedSurface === thirdFocus)
        #expect(destination.controller.focusedSurface === anchor, "the destination's focus is not moved")
        #expect(source.controller.focusedSurface === staying, "the source's focus leaves with the pane, to what is left")
        #expect(WorkspaceStore.shared.activeWorkspaceId == activeWorkspace)
    }

    @Test func aLonePaneClosesItsTabAndNoUndoCanLoseIt() throws {
        let undo = ExpiringUndoManager()
        undo.groupsByEvent = false
        let source = try tab(split: false, undo: undo), destination = try tab(split: false, undo: undo)
        defer { close(source, destination) }
        let anchor = try #require(destination.panes.first)
        undo.beginUndoGrouping()
        _ = try #require(destination.controller.newSplit(at: anchor, direction: .right))
        undo.endUndoGrouping()
        try #require(undo.canUndo, "the destination has split history to go wrong")
        let moving = try #require(source.panes.first)
        let (pty, pid) = try live(moving)
        defer { pty.terminate() }

        undo.beginUndoGrouping()
        try destination.controller.movePaneHere(moving, beside: anchor, direction: .right, select: false)
        undo.endUndoGrouping()
        #expect(destination.panes.count == 3 && destination.panes.firstIndex(of: moving) == 1, "right of the anchor")
        #expect(!TerminalController.all.contains { $0 === source.controller }, "the empty tab closed")
        // Undo everything still offered (the split made before the move
        // included), then redo it: the pane stays, in exactly this one tab.
        // Emptied groups may remain on the stack; undoing them changes nothing.
        let layout = destination.panes.map(\.id)
        for _ in 0..<5 where undo.canUndo { undo.undo() }
        #expect(destination.panes.map(\.id) == layout, "no older snapshot takes the pane out")
        for _ in 0..<5 where undo.canRedo { undo.redo() }
        #expect(destination.panes.map(\.id) == layout)
        #expect(owners(of: moving).map(ObjectIdentifier.init) == [ObjectIdentifier(destination.controller)])
        #expect(moving.pty === pty && pty.alive && moving.pid == pid)
    }

    @Test func badMovesAreRefusedAndChangeNothing() throws {
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        let moving = source.panes[1], anchor = try #require(destination.panes.first)
        let windows = TerminalController.all.count
        let before = (source.panes.map(\.id), destination.panes.map(\.id))
        let tabs = [source, destination]

        #expect(failure(move(moving, into: moving, tabs: tabs))?.contains("beside itself") == true)
        #expect(failure(move(moving, into: anchor, tabs: tabs, ["split": .string("diagonal")]))?.contains("--split takes") == true)
        #expect(failure(move(moving, into: anchor, tabs: tabs, ["split": .number(7)]))?.contains("--split takes") == true)
        #expect(failure(move(moving, into: anchor, tabs: tabs, ["window": .string("new")]))?.contains("not both") == true)
        #expect(failure(move(moving, into: anchor, tabs: tabs, ["into": .number(42)]))?.contains("pane id") == true)
        #expect(failure(move(moving, into: anchor, tabs: tabs, ["into": .string("")]))?.contains("pane id") == true)
        #expect(failure(move(moving, into: anchor, tabs: tabs, ["into": .string(UUID().uuidString)])) != nil)
        var noInto = ["action": JSON.string("move"), "target": .string(moving.id.uuidString), "split": .string("left")]
        noInto["select"] = .bool(false)
        let previous = ControlCommands.mode
        ControlCommands.mode = .on
        let all = tabs.flatMap { t in t.panes.map { ControlCommands.Pane(surface: $0, windowID: "w", tabID: "t", controller: t.controller) } }
        let splitAlone = ControlCommands.handle(ControlRequest(cmd: "pane", args: noInto), all: all)
        ControlCommands.mode = previous
        #expect(failure(splitAlone)?.contains("goes with --into") == true, "never a new window instead")

        #expect((source.panes.map(\.id), destination.panes.map(\.id)) == before)
        #expect(TerminalController.all.count == windows, "no window opened or closed")
    }

    @Test func withinItsOwnTabAPaneOnlyChangesPlace() throws {
        let source = try tab(split: true)
        defer { close(source) }
        let first = source.panes[0], second = source.panes[1]
        guard case .ok = move(first, into: second, tabs: [source]) else {
            Issue.record("pane move --into its own tab failed")
            return
        }
        #expect(source.panes.map(\.id) == [second.id, first.id])
        #expect(TerminalController.all.contains { $0 === source.controller })
    }

    @Test func selectingSwitchesToTheDestinationsWorkspaceTabAndPane() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let styles = ScopedAppearanceStore(fileURL: dir.appendingPathComponent("Appearance.json"))
        let here = workspaces.createWorkspace(name: "Here"), there = workspaces.createWorkspace(name: "There")
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        workspaces.assignTab(tabIdentifier: source.window.stableTabIdentifier, to: here.id)
        workspaces.assignTab(tabIdentifier: destination.window.stableTabIdentifier, to: there.id)
        #expect(workspaces.switchWorkspace(to: here.id))
        let moving = source.panes[1], anchor = try #require(destination.panes.first)

        try destination.controller.movePaneHere(moving, beside: anchor, direction: .right, select: true,
                                                appearance: styles, workspaces: workspaces)
        #expect(workspaces.activeWorkspaceId == there.id, "the hidden destination workspace is now the active one")
        #expect(Tako.CustomTabGroup.group(for: destination.window).selectedWindow === destination.window)
        #expect(destination.controller.focusedSurface === moving, "the keyboard goes with the pane")
    }

    @Test func thePaneKeepsWhatItInheritedAndItsOwnPresetAsWritten() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let styles = ScopedAppearanceStore(fileURL: dir.appendingPathComponent("Appearance.json"))
        let main = workspaces.createWorkspace(name: "Main"), legal = workspaces.createWorkspace(name: "Legal")
        let source = try tab(split: true), destination = try tab(split: false), other = try tab(split: false)
        defer { close(source, destination, other) }
        let sourceTab = source.window.stableTabIdentifier
        workspaces.assignTab(tabIdentifier: sourceTab, to: main.id)
        workspaces.assignTab(tabIdentifier: destination.window.stableTabIdentifier, to: main.id)
        workspaces.assignTab(tabIdentifier: other.window.stableTabIdentifier, to: legal.id)
        try styles.setValue("#010101", for: "background", scope: .session(sourceTab))
        try styles.setValue("17", for: "font-size", scope: .session(sourceTab))
        try styles.setValue("#0a0a0a", for: "foreground", scope: .workspace(main.id))
        let inheriting = source.panes[1], owned = source.panes[0]
        try styles.setValue("Anything", for: "theme", scope: .pane(owned.id))
        let anchor = try #require(destination.panes.first), far = try #require(other.panes.first)

        // Same workspace: the old session's fields travel; the workspace parent is shared.
        try destination.controller.movePaneHere(inheriting, beside: anchor, direction: .right, select: false,
                                                appearance: styles, workspaces: workspaces)
        #expect(styles.document.overrides(for: .pane(inheriting.id)) == ["background": "#010101", "font-size": "17"])
        // Another workspace: the old workspace's fields travel too; an own preset is left as written.
        try other.controller.movePaneHere(owned, beside: far, direction: .right, select: false,
                                          appearance: styles, workspaces: workspaces)
        #expect(styles.document.overrides(for: .pane(owned.id)) == ["theme": "Anything"])
        try other.controller.movePaneHere(inheriting, beside: far, direction: .down, select: false,
                                          appearance: styles, workspaces: workspaces)
        #expect(styles.document.overrides(for: .pane(inheriting.id)) ==
                ["background": "#010101", "font-size": "17", "foreground": "#0a0a0a"])
        #expect(styles.document.overrides(for: .session(sourceTab))?["background"] == "#010101", "the source record is untouched")
    }

    @Test func aSharedWorkspacesStyleSurvivesADestinationSessionThatOverridesIt() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let file = dir.appendingPathComponent("Appearance.json")
        let styles = ScopedAppearanceStore(fileURL: file)
        let shared = workspaces.createWorkspace(name: "Shared")
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        let destinationTab = destination.window.stableTabIdentifier
        for tab in [source.window.stableTabIdentifier, destinationTab] { workspaces.assignTab(tabIdentifier: tab, to: shared.id) }
        try styles.setValue("#111111", for: "background", scope: .workspace(shared.id))
        try styles.setValue("17", for: "font-size", scope: .workspace(shared.id))
        try styles.setValue("#eeeeee", for: "background", scope: .session(destinationTab))
        try styles.setValue("25", for: "font-size", scope: .session(destinationTab))
        let moving = source.panes[1], anchor = try #require(destination.panes.first)
        let before = styles.effectiveTheme(global: .takoDefault, workspaceID: shared.id,
                                           sessionID: source.window.stableTabIdentifier, paneID: moving.id)

        try destination.controller.movePaneHere(moving, beside: anchor, direction: .right, select: false,
                                                appearance: styles, workspaces: workspaces)
        let reloaded = ScopedAppearanceStore(fileURL: file)
        let after = reloaded.effectiveTheme(global: .takoDefault, workspaceID: shared.id, sessionID: destinationTab, paneID: moving.id)
        #expect(after.background == before.background && after.fontSize == before.fontSize && after.fontSize == 17,
                "the moved pane keeps the shared workspace's look, not the destination session's")
        let neighbour = reloaded.effectiveTheme(global: .takoDefault, workspaceID: shared.id, sessionID: destinationTab, paneID: anchor.id)
        #expect(neighbour.fontSize == 25, "the destination's own pane keeps its session's look")
    }

    @Test func withNoSelectASelectedButBackgroundSourceIsNotMarkedSeen() throws {
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        let moving = source.panes[1], staying = source.panes[0]
        source.controller.focusedSurface = moving
        // The source is its group's selected tab, but its window is not the key window of an active app.
        #expect(Tako.CustomTabGroup.group(for: source.window).selectedWindow === source.window)
        #expect(!(NSApp.isActive && source.window.isKeyWindow))
        NotificationStore.shared.addNotification(id: "move-unread-\(staying.id)", surfaceId: staying.id,
                                                 paneTitle: "staying", title: "done", body: "")
        defer { NotificationStore.shared.markRead(surfaceId: staying.id) }
        let anchor = try #require(destination.panes.first)
        destination.controller.focusedSurface = anchor
        let workspace = WorkspaceStore.shared.activeWorkspaceId

        try destination.controller.movePaneHere(moving, beside: anchor, direction: .right, select: false)
        #expect(NotificationStore.shared.unreadCount(for: staying.id) == 1, "nobody looked at the pane left behind")
        #expect(source.controller.focusedSurface === staying, "its logical focus moved")
        #expect(destination.controller.focusedSurface === anchor)
        #expect(WorkspaceStore.shared.activeWorkspaceId == workspace)
    }

    @Test func aStyleThatCannotBeKeptRefusesTheMoveWithBothTabsUnchanged() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let file = dir.appendingPathComponent("Appearance.json")
        let styles = ScopedAppearanceStore(fileURL: file)
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        try styles.setValue("#010101", for: "background", scope: .session(source.window.stableTabIdentifier))
        try "{\"version\": 2, \"sessions\": {}}".write(to: file, atomically: true, encoding: .utf8)  // edited outside Tako
        let moving = source.panes[1], anchor = try #require(destination.panes.first)
        let before = (source.panes.map(\.id), destination.panes.map(\.id))

        #expect(throws: MovePaneError.self) {
            try destination.controller.movePaneHere(moving, beside: anchor, direction: .right, select: false,
                                                    appearance: styles, workspaces: workspaces)
        }
        #expect((source.panes.map(\.id), destination.panes.map(\.id)) == before)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"version\": 2, \"sessions\": {}}")
    }

    @Test func theMenuListsTheOtherTabsOfTheWorkspaceAndMovesThePane() throws {
        let source = try tab(split: false), destination = try tab(split: false)
        defer { close(source, destination) }
        let moving = try #require(source.panes.first)
        if let workspace = WorkspaceStore.shared.workspace(forTab: source.window.stableTabIdentifier) {
            WorkspaceStore.shared.assignTab(tabIdentifier: destination.window.stableTabIdentifier, to: workspace.id)
        }
        destination.window.title = "Codex"

        let destinations = MovePaneToTab.destinations(for: moving)
        #expect(destinations.contains { $0 === destination.controller })
        #expect(!destinations.contains { $0 === source.controller }, "never its own tab")

        let item = MovePaneToTab.menuItem(for: moving)
        #expect(item.identifier?.rawValue == "PaneMenuMoveToTab" && item.isEnabled)
        let entry = try #require(item.submenu?.items.first { $0.title == "Codex" } as? SidebarMenuAction)
        _ = entry.target?.perform(entry.action, with: entry)
        #expect(destination.panes.contains(moving))
        #expect(!TerminalController.all.contains { $0 === source.controller })
    }
}
