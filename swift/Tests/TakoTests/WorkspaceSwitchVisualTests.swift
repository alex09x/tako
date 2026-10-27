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

/// Agent tabs and terminals in three workspaces, and the session sidebar as a
/// window draws it, through switches between the workspaces: every tab stays
/// listed and drawn, with its status, and the selection follows the switch.
/// Set TAKO_WS_FRAMES_DIR to keep the frames.
@Suite(.serialized) @MainActor
struct WorkspaceSwitchVisualTests {
    private struct Row: Equatable { let title: String; let status: Tako.PaneStatus; let isChild: Bool }

    private func rows(_ scene: WorkspaceSwitchVisualScene) -> [String: [Row]] {
        Dictionary(uniqueKeysWithValues: scene.groups.map { group in
            (group.name, group.items.map { Row(title: $0.title, status: $0.status, isChild: $0.isChild) })
        })
    }

    private let expected: [String: [Row]] = [
        "Default": [Row(title: "Claude · petition", status: .working, isChild: false),
                    Row(title: "tail -f app.log", status: .idle, isChild: false)],
        "Legal": [Row(title: "Codex · review", status: .needsApproval, isChild: false),
                  Row(title: "Codex · review", status: .working, isChild: true),
                  Row(title: "Antigravity · brief", status: .needsApproval, isChild: true),
                  Row(title: "Claude · exhibits", status: .done, isChild: false)],
        "Frontend": [Row(title: "Vite dev", status: .waitingForInput, isChild: false),
                     Row(title: "zsh", status: .idle, isChild: false)],
    ]

    @Test func everyTabOfEveryWorkspaceStaysListedWithItsStatusThroughTheSwitches() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        scene.populate()
        #expect(rows(scene) == expected)
        let tour = [scene.legal, scene.frontend, scene.main, scene.frontend, scene.legal, scene.main]
        for (step, workspace) in tour.enumerated() {
            scene.switchTo(workspace)
            #expect(scene.workspaces.activeWorkspaceId == workspace.id, "step \(step)")
            #expect(rows(scene) == expected, "after switching to \(workspace.name)")
            let active = scene.groups.filter(\.isActive).map(\.name)
            #expect(active == [workspace.name])
            // The switch selects a tab of the workspace it went to.
            let selected = Tako.CustomTabGroup.group(for: scene.anchor).selectedWindow
            #expect(scene.tabs.first(where: { $0.window === selected })?.workspace == workspace.id)
        }
        for tab in scene.tabs { #expect(!tab.window.isReleasedWhenClosed, "no tab was closed by a switch") }
    }

    @Test func theSidebarIsDrawnTheSameAfterARoundTripOfSwitches() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        scene.populate()
        let before = scene.snapshot()
        scene.export(before, "roundtrip-0-default")
        for workspace in [scene.legal, scene.frontend, scene.main] {
            scene.switchTo(workspace)
            scene.export(scene.snapshot(), "roundtrip-\(workspace.name)")
        }
        let after = scene.snapshot()
        let changed = SidebarPixels.differingFraction(before, after)
        #expect(changed < 0.002, "\(Int(changed * 100_000)) of 100000 pixels differ after Default -> Legal -> Frontend -> Default")
    }

    @Test func theSelectionBarMovesToTheWorkspaceSwitchedTo() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        scene.populate()
        var bars: [String: ClosedRange<Int>] = [:]
        for workspace in [scene.main, scene.legal, scene.frontend] {
            scene.switchTo(workspace)
            let frame = scene.snapshot()
            scene.export(frame, "selection-\(workspace.name)")
            let runs = SidebarPixels.accentRuns(frame, column: 2)
            #expect(runs.count == 1, "one selection bar in \(workspace.name), found \(runs)")
            bars[workspace.name] = runs.first
        }
        guard let d = bars["Default"], let l = bars["Legal"], let f = bars["Frontend"] else { return }
        #expect(d.upperBound < l.lowerBound && l.upperBound < f.lowerBound,
                "the bar follows the switch down the list: \(d) \(l) \(f)")
    }

    @Test func aWorkingAgentInAWorkspaceYouLeftDoesNotAskForYou() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        scene.populate()
        let defaultAttention = scene.groups.first { $0.name == "Default" }?.attentionCount
        #expect(defaultAttention == 0)
        scene.switchTo(scene.legal)
        let left = scene.groups.first { $0.name == "Default" }
        #expect(left?.attentionCount == 0, "only a working Claude and an idle shell are there")
        #expect(left?.items.first?.needsAttention == false)
        // What does ask for you still does: the approval, the question, the unseen outcome.
        scene.switchTo(scene.main)
        let legal = scene.groups.first { $0.name == "Legal" }
        #expect(legal?.attentionCount == 2)
        #expect(scene.groups.first { $0.name == "Frontend" }?.attentionCount == 1)
    }
}

/// A workspace's tabs may live in a window of their own -- the first tab of
/// a workspace that had none opens one. The sidebar of another workspace's
/// window lists them all the same, with their count.
@Suite(.serialized) @MainActor
struct WorkspaceTabsInOtherWindowsTests {
    @Test func theSidebarListsTabsThatLiveInAnotherWindow() throws {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        // The window the user is in: Legal's two agents.
        scene.addTab(scene.surface("Claude · petition", .working), to: scene.legal)
        scene.addTab(scene.surface("Codex · review", .needsApproval), to: scene.legal)
        // Default's one tab, in its own window, and Frontend's, in another.
        let top = scene.addTab(scene.surface("top", .idle), to: scene.main, ownWindow: true)
        let vite = scene.addTab(scene.surface("Vite dev", .waitingForInput), to: scene.frontend, ownWindow: true)
        _ = scene.workspaces.switchWorkspace(to: scene.legal.id)
        scene.mountSidebar()

        let byName = Dictionary(uniqueKeysWithValues: scene.groups.map { ($0.name, $0) })
        #expect(byName["Legal"]?.sessionCount == 2)
        #expect(byName["Default"]?.sessionCount == 1, "Default's tab lives in another window, and counts")
        #expect(byName["Default"]?.items.map(\.title) == ["top"])
        #expect(byName["Frontend"]?.items.map(\.title) == ["Vite dev"])
        #expect(byName["Frontend"]?.attentionCount == 1)
        let selected = scene.groups.flatMap(\.items).filter(\.isSelected).map(\.title)
        #expect(selected.count <= 1, "one selected row, the own window's: \(selected)")
        #expect(!selected.contains("top") && !selected.contains("Vite dev"))
        scene.export(scene.snapshot(), "other-windows-legal")

        // A click on Default's row goes to its window and its workspace.
        let row = try #require(byName["Default"]?.items.first)
        scene.store.selectTab(item: row, in: scene.anchor, workspaceStore: scene.workspaces)
        #expect(scene.workspaces.activeWorkspaceId == scene.main.id)
        #expect(Tako.CustomTabGroup.group(for: top.window).selectedWindow === top.window)

        // And a click on Frontend's header to its own.
        scene.store.selectWorkspace(scene.frontend.id, in: scene.anchor, workspaceStore: scene.workspaces)
        #expect(scene.workspaces.activeWorkspaceId == scene.frontend.id)
        #expect(Tako.CustomTabGroup.group(for: vite.window).selectedWindow === vite.window)
    }

    @Test func aTabOfNoWorkspaceInAnotherWindowIsNotPulledIn() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        scene.addTab(scene.surface("Claude · petition", .working), to: scene.legal)
        // A stray window no workspace holds -- another test's, another app's state.
        let stray = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        stray.isReleasedWhenClosed = false
        defer { stray.close() }
        _ = Tako.CustomTabGroup.group(for: stray)
        _ = scene.workspaces.switchWorkspace(to: scene.legal.id)
        scene.mountSidebar()
        let titles = scene.groups.flatMap(\.items).map(\.title)
        #expect(titles == ["Claude · petition"])
    }
}

/// Reading a sidebar frame.
enum SidebarPixels {
    /// The share of pixels whose colour moved by more than a rounding step.
    static func differingFraction(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var differing = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: a.pixelsWide, by: 1) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.03 || abs(p.greenComponent - q.greenComponent) > 0.03
                    || abs(p.blueComponent - q.blueComponent) > 0.03 { differing += 1 }
            }
        }
        return Double(differing) / Double(a.pixelsWide * a.pixelsHigh)
    }

    /// Runs of the ember accent down one pixel column: the selected row's bar.
    static func accentRuns(_ rep: NSBitmapImageRep, column x: Int) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0..<rep.pixelsHigh {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            let accent = c.map { $0.redComponent > 0.75 && $0.greenComponent < 0.55 && $0.blueComponent < 0.35 } ?? false
            if accent, start == nil { start = y }
            if !accent, let s = start { if y - s >= 8 { runs.append(s...(y - 1)) }; start = nil }
        }
        if let s = start, rep.pixelsHigh - s >= 8 { runs.append(s...(rep.pixelsHigh - 1)) }
        return runs
    }
}
