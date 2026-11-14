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
/// tab it leaves empty closes, one it leaves with panes stays.
@MainActor @Suite(.serialized)
struct ControlPaneMoveIntoTabTests {
    @MainActor private struct Tab {
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

    private func close(_ tabs: Tab...) {
        for tab in tabs {
            tab.window.close()
            TerminalTestSupport.tearDown(tab.controller, tab.window)
        }
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

    @Test func aPaneJoinsAnotherTabBesideAPaneThereAndItsOldTabKeepsTheRest() throws {
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        let moving = source.panes[1], staying = source.panes[0]
        let anchor = try #require(destination.panes.first)
        let pty = moving.pty

        guard case .ok(let result) = move(moving, into: anchor, tabs: [source, destination], ["split": .string("down")]) else {
            Issue.record("pane move --into failed")
            return
        }
        #expect(result["id"]?.string == moving.id.uuidString.lowercased())
        #expect(result["into"]?.string == anchor.id.uuidString.lowercased())
        #expect(destination.panes.map(\.id) == [anchor.id, moving.id], "below the anchor, in its tab")
        #expect(moving.pty === pty, "the same process, not a new one")
        #expect(source.panes.map(\.id) == [staying.id])
        #expect(TerminalController.all.contains { $0 === source.controller }, "a tab with panes left stays open")
    }

    @Test func aLonePaneLeavesItsTabClosedBehindIt() throws {
        let source = try tab(split: false), destination = try tab(split: true)
        defer { close(source, destination) }
        let moving = try #require(source.panes.first)
        let anchor = destination.panes[0]
        let pty = moving.pty

        guard case .ok = move(moving, into: anchor, tabs: [source, destination]) else {
            Issue.record("pane move --into failed")
            return
        }
        #expect(destination.panes.count == 3 && destination.panes.contains(moving))
        #expect(destination.panes.firstIndex(of: moving) == 1, "right of the anchor by default")
        #expect(moving.pty === pty)
        #expect(source.controller.surfaceTree.isEmpty)
        #expect(!TerminalController.all.contains { $0 === source.controller }, "the empty tab closed")
    }

    @Test func badMovesAreRefusedAndChangeNothing() throws {
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        let moving = source.panes[1], anchor = try #require(destination.panes.first)
        let before = (source.panes.map(\.id), destination.panes.map(\.id))

        #expect(failure(move(moving, into: moving, tabs: [source, destination]))?.contains("beside itself") == true)
        #expect(failure(move(moving, into: anchor, tabs: [source, destination], ["split": .string("diagonal")]))?
            .contains("--split takes") == true)
        #expect(failure(move(moving, into: anchor, tabs: [source, destination], ["window": .string("new")]))?
            .contains("not both") == true)
        #expect(failure(move(moving, into: anchor, tabs: [source, destination], ["into": .string(UUID().uuidString)])) != nil)
        #expect((source.panes.map(\.id), destination.panes.map(\.id)) == before)
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
