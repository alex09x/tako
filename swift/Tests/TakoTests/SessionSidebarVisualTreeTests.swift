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
import SwiftUI
import Testing
@testable import Tako
@testable import TakoKit

@Suite(.serialized)
@MainActor
struct SessionSidebarVisualTreeTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.tako.sidebar.visual.tree.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeWorkspaceStore() -> (WorkspaceStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-ws-tree-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspaces.json")
        let wsStore = WorkspaceStore(storeURL: url, isTesting: true)
        wsStore.resetForTesting()
        return (wsStore, dir)
    }

    private func makeSurface(
        title: String,
        pwd: String = "/Users/alex/tako",
        status: Tako.PaneStatus = .idle,
        frame: NSRect = NSRect(x: 0, y: 0, width: 200, height: 200)
    ) -> Tako.SurfaceView {
        let view = Tako.SurfaceView(frame: frame)
        view.title = title
        view.pwd = pwd
        view.crab.setStatus(status, text: nil)
        return view
    }

    @Test func allPaneStatusesRenderAccurateSidebarDotColorsBadgesAndPulseState() {
        let prevOverride = Tako.overrideTabStatusTheme
        defer { Tako.overrideTabStatusTheme = prevOverride }
        Tako.overrideTabStatusTheme = nil

        // 1. Idle -> Gray (#8a7f76), no badge, no pulse
        #expect(Tako.PaneStatus.idle.dotKey == "dim")
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.idle.sidebarDotColor) == "#8a7f76")
        #expect(Tako.PaneStatus.idle.sidebarBadgeLabel == nil)
        #expect(!Tako.PaneStatus.idle.isSidebarPulsing)

        // 2. Working / Running -> Orange (#f4581c), "Working" badge, pulsing
        for status in [Tako.PaneStatus.working, Tako.PaneStatus.running] {
            #expect(status.dotKey == "ember")
            #expect(Tako.Brand.hexString(for: status.sidebarDotColor) == "#f4581c")
            #expect(status.sidebarBadgeLabel == "Working")
            #expect(status.isSidebarPulsing)
        }

        // 3. Waiting for Input -> Amber (#ff7a3d), "Needs Input" badge
        #expect(Tako.PaneStatus.waitingForInput.dotKey == "claw")
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.waitingForInput.sidebarDotColor) == "#ff7a3d")
        #expect(Tako.PaneStatus.waitingForInput.sidebarBadgeLabel == "Needs Input")
        #expect(!Tako.PaneStatus.waitingForInput.isSidebarPulsing)

        // 4. Needs Approval -> Amber (#ff7a3d), "Approval" badge
        #expect(Tako.PaneStatus.needsApproval.dotKey == "claw")
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.needsApproval.sidebarDotColor) == "#ff7a3d")
        #expect(Tako.PaneStatus.needsApproval.sidebarBadgeLabel == "Approval")
        #expect(!Tako.PaneStatus.needsApproval.isSidebarPulsing)

        // 5. Error -> Red (#d54e53), "Failed" badge
        #expect(Tako.PaneStatus.error.dotKey == "error")
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.error.sidebarDotColor) == "#d54e53")
        #expect(Tako.PaneStatus.error.sidebarBadgeLabel == "Failed")

        // 6. Done -> Green (#7bd88f), "Done" badge
        #expect(Tako.PaneStatus.done.dotKey == "ok")
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.done.sidebarDotColor) == "#7bd88f")
        #expect(Tako.PaneStatus.done.sidebarBadgeLabel == "Done")

        // 7. Custom theme override dynamically recolors sidebar status dots
        let customTheme = TerminalTheme.parse(
            config: """
            tab-status-color-working = #FF5500
            tab-status-color-waiting = #FFCC00
            tab-status-color-done = #00DD66
            tab-status-color-error = #FF1133
            tab-status-color-idle = #8899AA
            """
        )
        Tako.overrideTabStatusTheme = customTheme
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.working.sidebarDotColor) == "#ff5500")
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.needsApproval.sidebarDotColor) == "#ffcc00")
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.done.sidebarDotColor) == "#00dd66")
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.error.sidebarDotColor) == "#ff1133")
        #expect(Tako.Brand.hexString(for: Tako.PaneStatus.idle.sidebarDotColor) == "#8899aa")
    }

    @Test func workspaceSessionSplitPaneThreeLevelTreeStructureAndLiveStatusAggregation() {
        let defaults = makeDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        let (wsStore, tempDir) = makeWorkspaceStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backendWs = wsStore.activeWorkspace
        let frontendWs = wsStore.createWorkspace(name: "Frontend", color: "green", icon: "globe")

        // Tab 1 (Backend): 2 split panes (API Server = working, DB Migration = needsApproval)
        let win1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let container1 = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let surf1a = makeSurface(title: "API Server", pwd: "/Users/dev/backend/api", status: .working, frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let surf1b = makeSurface(title: "DB Migration", pwd: "/Users/dev/backend/db", status: .needsApproval, frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        container1.addSubview(surf1a)
        container1.addSubview(surf1b)
        win1.contentView = container1

        // Tab 2 (Backend): 1 pane (Worker Queue = idle)
        let win2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let surf2 = makeSurface(title: "Worker Queue", pwd: "/Users/dev/backend/worker", status: .idle)
        win2.contentView = surf2

        // Tab 3 (Frontend): 2 split panes (Vite Dev = done, Playwright = error)
        let win3 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let container3 = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let surf3a = makeSurface(title: "Vite Dev", pwd: "/Users/dev/frontend/web", status: .done, frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let surf3b = makeSurface(title: "Playwright E2E", pwd: "/Users/dev/frontend/e2e", status: .error, frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        container3.addSubview(surf3a)
        container3.addSubview(surf3b)
        win3.contentView = container3

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        Tako.CustomTabGroup.join(win3, to: win1, select: false)
        Tako.CustomTabGroup.group(for: win1).select(win2)

        wsStore.assignTab(tabIdentifier: win1.stableTabIdentifier, to: backendWs.id)
        wsStore.assignTab(tabIdentifier: win2.stableTabIdentifier, to: backendWs.id)
        wsStore.assignTab(tabIdentifier: win3.stableTabIdentifier, to: frontendWs.id)

        let groups = store.workspaceGroups(for: win1, workspaceStore: wsStore)
        #expect(groups.count == 2)

        // Level 0: Backend Workspace Group
        let gBackend = groups[0]
        #expect(gBackend.id == backendWs.id)
        #expect(gBackend.sessionCount == 2)
        #expect(gBackend.paneCount == 3)
        #expect(gBackend.dominantStatus == .needsApproval)
        #expect(gBackend.attentionCount == 1)
        // 2 session rows + 2 split-pane child rows under Tab 1 = 4 items
        #expect(gBackend.items.count == 4)

        // Level 1: Tab 1 parent row
        #expect(!gBackend.items[0].isChild)
        #expect(gBackend.items[0].hasChildren)
        #expect(gBackend.items[0].childrenSummary == "2 panes")
        #expect(gBackend.items[0].indentationLevel == 1)
        #expect(gBackend.items[0].status == .needsApproval)

        // Level 2: Tab 1 split pane children
        #expect(gBackend.items[1].isChild)
        #expect(gBackend.items[1].title == "API Server")
        #expect(gBackend.items[1].label == "pane 1")
        #expect(gBackend.items[1].status == .working)
        #expect(gBackend.items[1].indentationLevel == 2)

        #expect(gBackend.items[2].isChild)
        #expect(gBackend.items[2].title == "DB Migration")
        #expect(gBackend.items[2].label == "pane 2")
        #expect(gBackend.items[2].status == .needsApproval)
        #expect(gBackend.items[2].needsAttention)
        #expect(gBackend.items[2].indentationLevel == 2)

        // Level 0: Frontend Workspace Group
        let gFrontend = groups[1]
        #expect(gFrontend.id == frontendWs.id)
        #expect(gFrontend.name == "Frontend")
        #expect(gFrontend.sessionCount == 1)
        #expect(gFrontend.paneCount == 2)
        #expect(gFrontend.dominantStatus == .error)
        #expect(gFrontend.attentionCount == 1)
        #expect(gFrontend.items.count == 3)
        #expect(gFrontend.items[1].title == "Vite Dev")
        #expect(gFrontend.items[1].status == .done)
        #expect(gFrontend.items[2].title == "Playwright E2E")
        #expect(gFrontend.items[2].status == .error)
    }

    @Test func interactiveTreeCollapseExpandAndClickFocusesExactWorkspaceTabAndSplitPane() {
        let defaults = makeDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        let (wsStore, tempDir) = makeWorkspaceStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backendWs = wsStore.activeWorkspace
        let frontendWs = wsStore.createWorkspace(name: "Frontend", color: "green")

        let win1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let container1 = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let surf1a = makeSurface(title: "API Server", status: .working, frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let surf1b = makeSurface(title: "DB Migration", status: .needsApproval, frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        container1.addSubview(surf1a)
        container1.addSubview(surf1b)
        win1.contentView = container1

        let win2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let container2 = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let surf2a = makeSurface(title: "Vite Dev", status: .idle, frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let surf2b = makeSurface(title: "Playwright E2E", status: .error, frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        container2.addSubview(surf2a)
        container2.addSubview(surf2b)
        win2.contentView = container2

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        let group = Tako.CustomTabGroup.group(for: win1)
        group.select(win1)

        wsStore.assignTab(tabIdentifier: win1.stableTabIdentifier, to: backendWs.id)
        wsStore.assignTab(tabIdentifier: win2.stableTabIdentifier, to: frontendWs.id)

        // 1. Collapse Tab 1's split panes -> only parent row remains in Backend group
        store.toggleTabSplitsCollapsed(win1.stableTabIdentifier)
        #expect(store.isTabSplitsCollapsed(win1.stableTabIdentifier))
        let afterTabCollapse = store.workspaceGroups(for: win1, workspaceStore: wsStore)
        #expect(afterTabCollapse[0].items.count == 1)
        #expect(afterTabCollapse[0].items[0].isCollapsed)
        #expect(afterTabCollapse[0].items[0].childrenSummary == "2 panes")

        // Expand Tab 1's split panes back
        store.toggleTabSplitsCollapsed(win1.stableTabIdentifier)
        #expect(store.workspaceGroups(for: win1, workspaceStore: wsStore)[0].items.count == 3)

        // 2. Collapse Frontend Workspace -> items hidden, header counts preserved
        store.toggleWorkspaceCollapsed(frontendWs.id)
        let afterWsCollapse = store.workspaceGroups(for: win1, workspaceStore: wsStore)
        #expect(afterWsCollapse[1].isCollapsed)
        #expect(afterWsCollapse[1].items.isEmpty)
        #expect(afterWsCollapse[1].sessionCount == 1)
        #expect(afterWsCollapse[1].attentionCount == 1)

        // 3. Search filter automatically surfaces matching split pane even inside collapsed workspace
        store.setFilterText("Playwright", for: win1)
        let searched = store.workspaceGroups(for: win1, workspaceStore: wsStore)
        #expect(searched.count == 1)
        #expect(searched[0].id == frontendWs.id)
        #expect(searched[0].items.contains(where: { $0.isChild && $0.title == "Playwright E2E" }))
        store.setFilterText("", for: win1)
        store.setWorkspaceCollapsed(frontendWs.id, collapsed: false)

        // 4. Click child split pane 2 ("Playwright E2E") in Frontend workspace ->
        // switches active workspace to Frontend, selects win2, and focuses surf2b
        let fullGroups = store.workspaceGroups(for: win1, workspaceStore: wsStore)
        let playwrightItem = fullGroups[1].items.first(where: { $0.isChild && $0.title == "Playwright E2E" })!
        store.selectTab(item: playwrightItem, in: win1, workspaceStore: wsStore)

        #expect(wsStore.activeWorkspaceId == frontendWs.id)
        #expect(group.selectedWindow === win2)
        #expect(win2.firstResponder === surf2b)

        // 5. Click Backend Workspace header -> switches back to Backend and selects win1
        store.selectWorkspace(backendWs.id, in: win2, workspaceStore: wsStore)
        #expect(wsStore.activeWorkspaceId == backendWs.id)
        #expect(group.selectedWindow === win1)
    }

    @Test func visualRenderingOfSessionSidebarTreeAndPaneOverviewReflectsLiveStatusTransitions() {
        let defaults = makeDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        let (wsStore, tempDir) = makeWorkspaceStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let backendWs = wsStore.activeWorkspace
        let frontendWs = wsStore.createWorkspace(name: "Frontend", color: "purple")

        let surf1 = makeSurface(title: "Claude Agent", pwd: "/Users/dev/backend", status: .idle)
        let surf2 = makeSurface(title: "Codex Reviewer", pwd: "/Users/dev/backend", status: .working)
        var tree1 = SplitTree<Tako.SurfaceView>(view: surf1)
        tree1 = (try? tree1.inserting(view: surf2, at: surf1, direction: .right)) ?? tree1
        let ctrl1 = BaseTerminalController(Tako.App(), surfaceTree: tree1)
        let win1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win1.windowController = ctrl1
        ctrl1.window = win1
        let container1 = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        container1.addSubview(surf1)
        container1.addSubview(surf2)
        win1.contentView = container1

        let surf3 = makeSurface(title: "Vite Frontend", pwd: "/Users/dev/frontend", status: .done)
        let ctrl2 = BaseTerminalController(Tako.App(), surfaceTree: SplitTree(view: surf3))
        let win2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win2.windowController = ctrl2
        ctrl2.window = win2
        win2.contentView = surf3

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        wsStore.assignTab(tabIdentifier: win1.stableTabIdentifier, to: backendWs.id)
        wsStore.assignTab(tabIdentifier: win2.stableTabIdentifier, to: frontendWs.id)

        // Mount SessionSidebarView in an offscreen host window and verify rendered pixels across live status transitions
        let renderWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let sidebarHosting = NSHostingView(
            rootView: SessionSidebarView(
                isPresented: .constant(true),
                containingWindow: win1,
                store: store,
                workspaceStore: wsStore
            )
        )
        sidebarHosting.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        renderWin.contentView = sidebarHosting
        defer { renderWin.close() }

        let lifecycle: [Tako.PaneStatus] = [.idle, .working, .waitingForInput, .needsApproval, .error, .done]
        for nextStatus in lifecycle {
            surf1.crab.setStatus(nextStatus, text: "Step \(nextStatus.rawValue)")
            sidebarHosting.layoutSubtreeIfNeeded()
            let groups = store.workspaceGroups(for: win1, workspaceStore: wsStore)
            let child1 = groups[0].items.first(where: { $0.surfaceId == surf1.id && $0.isChild })
            #expect(child1?.status == nextStatus)
            #expect(child1?.status.sidebarBadgeLabel == nextStatus.sidebarBadgeLabel)

            guard let rep = sidebarHosting.bitmapImageRepForCachingDisplay(in: sidebarHosting.bounds) else {
                Issue.record("Failed to create bitmap rep for SessionSidebarView")
                return
            }
            sidebarHosting.cacheDisplay(in: sidebarHosting.bounds, to: rep)
            #expect(rep.pixelsWide >= 260 && rep.pixelsHigh >= 600)
        }

        // Verify PaneOverviewStore discovers all 3 panes with Workspace provenance and filters by workspaceName
        let overviewStore = PaneOverviewStore()
        overviewStore.refresh(fromControllers: [ctrl1, ctrl2], workspaceStore: wsStore)
        #expect(overviewStore.items.count == 3)
        #expect(overviewStore.items.filter { $0.workspaceName == "Default" }.count == 2)
        #expect(overviewStore.items.filter { $0.workspaceName == "Frontend" }.count == 1)

        overviewStore.filterText = "Frontend"
        #expect(overviewStore.filteredItems.count == 1)
        #expect(overviewStore.filteredItems[0].title == "Vite Frontend")

        // Live status change on surf3 immediately updates PaneOverviewStore item
        surf3.crab.setStatus(.needsApproval, text: "Approve deploy?")
        #expect(overviewStore.filteredItems[0].status == .needsApproval)
        #expect(overviewStore.filteredItems[0].statusLabel == "Needs Approval")
    }
}
