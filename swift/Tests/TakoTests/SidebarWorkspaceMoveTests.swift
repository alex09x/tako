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

@Suite(.serialized) @MainActor
struct SidebarWorkspaceMoveTests {
    @Test func onlyAnInternalDragCanNameATab() {
        #expect(SidebarTabTransfer.decode(SidebarTabTransfer.encode("tab-123")) == "tab-123")
        #expect(SidebarTabTransfer.decode("tab-123") == nil)
        #expect(SidebarTabTransfer.decode("tako-sidebar:\(UUID().uuidString):tab-123") == nil)
    }

    @Test func movingATabKeepsItsWindowAndSplitPanes() throws {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        let first = scene.surface("first", .idle)
        let split = scene.surface("second", .idle)
        let tab = scene.addTab(first, split: split, to: scene.main)
        let firstPTY = first.pty, secondPTY = split.pty
        let tabID = tab.window.stableTabIdentifier
        #expect(scene.store.moveTab(tabID, to: scene.legal.id, around: scene.anchor, workspaceStore: scene.workspaces))
        #expect(scene.workspaces.workspace(forTab: tabID)?.id == scene.legal.id)
        #expect(scene.workspaces.activeWorkspaceId == scene.legal.id)
        #expect(scene.workspaces.workspace(for: scene.legal.id)?.activeTabIdentifier == tabID)
        #expect(first.pty === firstPTY && split.pty === secondPTY)
        #expect(tab.controller.surfaceTree.contains { $0 === first })
        #expect(tab.controller.surfaceTree.contains { $0 === split })
    }

    @Test func anUnknownTabOrWorkspaceCannotChangeAssignments() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        let tab = scene.addTab(scene.surface("session", .idle), to: scene.main)
        let id = tab.window.stableTabIdentifier
        #expect(!scene.store.moveTab("unknown", to: scene.legal.id, around: scene.anchor, workspaceStore: scene.workspaces))
        #expect(!scene.store.moveTab(id, to: UUID(), around: scene.anchor, workspaceStore: scene.workspaces))
        #expect(scene.workspaces.workspace(forTab: id)?.id == scene.main.id)
    }

    @Test func bringingASeparateWindowIntoTheCurrentTabBarKeepsTheSamePane() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        let anchor = scene.addTab(scene.surface("first", .idle), to: scene.main)
        let surface = scene.surface("second", .idle)
        let other = scene.addTab(surface, to: scene.main, ownWindow: true)
        let oldPTY = surface.pty
        let id = other.window.stableTabIdentifier
        #expect(scene.store.canMoveTabToWindow(id, around: anchor.window, workspaceStore: scene.workspaces))
        #expect(scene.store.moveTabToWindow(id, around: anchor.window, workspaceStore: scene.workspaces))
        #expect(Tako.CustomTabGroup.group(for: anchor.window).windows.contains(other.window))
        #expect(surface.pty === oldPTY)
        #expect(scene.workspaces.workspace(forTab: id)?.id == scene.main.id)
    }

    @Test func aSingleCurrentWindowCanJoinAnExistingMultiTabWindow() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        let first = scene.addTab(scene.surface("first", .idle), to: scene.main)
        let second = scene.addTab(scene.surface("second", .idle), to: scene.main)
        let third = scene.addTab(scene.surface("third", .idle), to: scene.main, ownWindow: true)
        let id = first.window.stableTabIdentifier
        let oldPTY = third.surfaces[0].pty
        #expect(scene.store.moveTabToWindow(id, around: third.window, workspaceStore: scene.workspaces))
        let group = Tako.CustomTabGroup.group(for: third.window)
        #expect(group.windows.contains(first.window) && group.windows.contains(second.window) && group.windows.contains(third.window))
        #expect(third.surfaces[0].pty === oldPTY)
    }
}
