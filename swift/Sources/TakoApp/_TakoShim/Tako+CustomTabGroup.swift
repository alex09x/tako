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

// Replaces NSWindowTabGroup for windows with tabbingMode = .disallowed.
//
// AppKit's native tab bar cannot be hidden and stay hidden while a window's
// tabbingMode allows tabbing at all -- confirmed live: it re-asserts
// isTabBarVisible on its own layout schedule regardless of anything a
// titlebar accessory does (a reactive toggle spun into hundreds of
// thousands of calls a minute fighting it). The only way to show
// TabBarView's own styling instead is for AppKit to never manage tabbing
// for these windows in the first place -- tabbingMode = .disallowed --
// which means membership, order, and selection have to be modelled here
// instead of read from `window.tabGroup`. Verified first in an isolated
// standalone prototype (multi-window create/switch/close, 0% idle CPU, no
// native bar ever appeared) before this port.

extension Tako {
    @MainActor
    final class CustomTabGroup {
        var windows: [NSWindow] = []
        var selectedWindow: NSWindow?
        /// What the group's tab strips are moving (Tako+TabStripTransitions.swift).
        let transitions = TabStripTransitions()
        weak var pendingOrderOutWindow: NSWindow?
        var lastSelectedWindowByWorkspace: [UUID: NSWindow] = [:]
        var focusGeneration: Int = 0
        /// Test override for workspace window frame synchronization.
        var syncWindowFrameOverride: Bool?
        var syncWindowFrame: Bool {
            syncWindowFrameOverride ?? (NSApp.delegate as? AppDelegate)?.tako.config.workspaceSyncWindowFrame ?? false
        }

        func recordSelection(_ window: NSWindow, for workspaceId: UUID) {
            lastSelectedWindowByWorkspace[workspaceId] = window
            if visibleWindows.contains(window) {
                selectedWindow = window
            }
        }

        /// The most recent active window frame across all groups, captured before workspace switches
        /// or during window resize/selection so a new or returning workspace can inherit it.
        static var lastActiveWindowFrame: NSRect?

        /// Detects whether the process is executing within a test harness (swift-testing or XCTest).
        private static var isUnitTestEnvironment: Bool {
            let env = ProcessInfo.processInfo.environment
            if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil {
                return true
            }
            if NSClassFromString("XCTest") != nil {
                return true
            }
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-TestingLibraryVersion") {
                return true
            }
            let processName = ProcessInfo.processInfo.processName
            if processName.hasSuffix("PackageTests") || processName.contains("xctest") || processName.hasSuffix("Tests") {
                return true
            }
            return false
        }

        /// Explicit flag to suppress window ordering (makeKeyAndOrderFront / orderFront) during offscreen or model unit tests.
        /// In test environments, this defaults to true to isolate unit runs from the desktop window server unless
        /// explicitly opted in via TAKO_ENABLE_LIVE_WINDOW_TESTS=1.
        static var suppressWindowOrderingForTesting: Bool = {
            if ProcessInfo.processInfo.environment["TAKO_ENABLE_LIVE_WINDOW_TESTS"] == "1" {
                return false
            }
            return isUnitTestEnvironment
        }()

        /// Resets test overrides and cached group state for test isolation.
        static func resetForTesting() {
            lastActiveWindowFrame = nil
            groupsByWindow.removeAll()
            closedWindows.removeAllObjects()
            if ProcessInfo.processInfo.environment["TAKO_ENABLE_LIVE_WINDOW_TESTS"] == "1" {
                suppressWindowOrderingForTesting = false
            } else {
                suppressWindowOrderingForTesting = isUnitTestEnvironment
            }
        }

        static var groupsByWindow: [ObjectIdentifier: CustomTabGroup] = [:]
        static var workspaceObserverInstalled = false

        /// All distinct active groups.
        static var allGroups: [CustomTabGroup] {
            var seen = Set<ObjectIdentifier>()
            var result: [CustomTabGroup] = []
            for group in groupsByWindow.values {
                let id = ObjectIdentifier(group)
                if seen.insert(id).inserted {
                    result.append(group)
                }
            }
            return result
        }

        /// The windows belonging to the active workspace in this group, ordered by the workspace's tab order.
        var visibleWindows: [NSWindow] {
            let store = WorkspaceStore.shared
            let activeWs = store.activeWorkspace

            // Any window in this group assigned to the active workspace (or default if unassigned)
            let matching = windows.filter { win in
                let ws = store.workspace(forTab: win.stableTabIdentifier)
                if let ws {
                    return ws.id == activeWs.id
                }
                // Unassigned windows belong to the default workspace
                return activeWs.id == WorkspaceStore.defaultWorkspaceId
            }

            if activeWs.tabIdentifiers.isEmpty {
                return matching
            }

            // In the workspace's order, then the group's: each place looked
            // up once, not searched for in every comparison.
            return matching.enumerated()
                .map { (rank: store.rank(ofTab: $1.stableTabIdentifier, in: activeWs.id) ?? Int.max, order: $0, window: $1) }
                .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
                .map(\.window)
        }

        /// Read-only lookup of a window's existing tab group without creating a new group or mutating WorkspaceStore.
        static func existingGroup(for window: NSWindow) -> CustomTabGroup? {
            groupsByWindow[ObjectIdentifier(window)]
        }

        /// Tabs whose windows closed. A closed window can outlive its close
        /// and still be asked about -- by its own tab bar redrawing as it
        /// goes, by a script naming its pane -- and it used to become a
        /// group again, which the next workspace switch put on screen: an
        /// empty window with nothing in it.
        static let closedWindows = NSHashTable<NSWindow>.weakObjects()

        static func isClosed(_ window: NSWindow) -> Bool {
            closedWindows.contains(window)
        }

        /// A tab's window closing: it leaves its group for good.
        static func close(_ window: NSWindow) {
            closedWindows.add(window)
            leave(window)
        }

        /// The group a window belongs to, creating a fresh single-window
        /// group the first time a window is asked about. A closed window is
        /// a group of its own that nothing lists or shows.
        static func group(for window: NSWindow) -> CustomTabGroup {
            ensureWorkspaceObserver()
            if let existing = groupsByWindow[ObjectIdentifier(window)] {
                return existing
            }
            if closedWindows.contains(window) {
                let alone = CustomTabGroup()
                alone.windows = [window]
                return alone
            }
            let group = CustomTabGroup()
            group.windows = [window]
            group.selectedWindow = window
            groupsByWindow[ObjectIdentifier(window)] = group

            // Assign window to active workspace if unassigned
            let wsId = WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier)?.id ?? WorkspaceStore.shared.activeWorkspaceId
            if WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier) == nil {
                WorkspaceStore.shared.assignTab(tabIdentifier: window.stableTabIdentifier, to: wsId)
            }
            group.lastSelectedWindowByWorkspace[wsId] = window
            if window.isKeyWindow || NSApp.keyWindow === window {
                WorkspaceStore.shared.setActiveTab(tabIdentifier: window.stableTabIdentifier, in: wsId)
                lastActiveWindowFrame = window.frame
            }

            return group
        }

        /// Remove membership without closing the window or forgetting its workspace.
        private static func detachForTransfer(_ window: NSWindow) {
            let key = ObjectIdentifier(window)
            guard let source = groupsByWindow[key],
                  let index = source.windows.firstIndex(of: window) else { return }
            if let pending = source.pendingOrderOutWindow, pending !== window, pending !== source.selectedWindow {
                pending.orderOut(nil)
            }
            let shownIndex = source.visibleWindows.firstIndex(of: window)
            let wasVisible = window.isVisible
            source.windows.remove(at: index)
            source.focusGeneration += 1
            source.pendingOrderOutWindow = nil
            if let shownIndex { source.transitions.tabClosed(window, at: shownIndex) }
            if source.selectedWindow === window {
                if let next = source.visibleWindows.first {
                    source.selectedWindow = nil
                    if wasVisible && !next.isVisible && !suppressWindowOrderingForTesting {
                        next.order(.above, relativeTo: window.windowNumber)
                    }
                    source.select(next)
                }
                else { source.selectedWindow = nil }
            }
            source.lastSelectedWindowByWorkspace = source.lastSelectedWindowByWorkspace.filter {
                _, saved in saved !== window && source.windows.contains(saved)
            }
            if groupsByWindow[key] === source { groupsByWindow.removeValue(forKey: key) }
        }

        /// Regrouping may need a journal's anchor to leave an existing group.
        static func isolateForRegroup(_ window: NSWindow) {
            guard let source = groupsByWindow[ObjectIdentifier(window)], source.windows.count > 1 else { return }
            detachForTransfer(window)
        }

        /// Add `window` to the same group as `anchor` without closing it.
        static func join(_ window: NSWindow, to anchor: NSWindow, select: Bool) {
            ensureWorkspaceObserver()
            let target = group(for: anchor)
            if let source = groupsByWindow[ObjectIdentifier(window)], source !== target {
                detachForTransfer(window)
            }
            groupsByWindow[ObjectIdentifier(window)] = target

            // Assign window to active workspace if unassigned
            if WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier) == nil {
                WorkspaceStore.shared.assignTab(tabIdentifier: window.stableTabIdentifier, to: WorkspaceStore.shared.activeWorkspaceId)
            }

            guard !target.windows.contains(window) else {
                if select { target.select(window) }
                return
            }
            // Match the shared frame so switching to it is never a visible
            // jump -- the new tab's window was created at its own cascaded
            // position, not the group's.
            window.setFrame(anchor.frame, display: false)
            target.windows.append(window)
            if target.windows.count > 1 { target.transitions.tabAppeared(window) }
            if select {
                target.select(window)
            } else {
                window.orderOut(nil)
            }
            Tako.TabBarController.refreshAll()
        }

        /// Insert `window` into `anchor`'s group at a specific index (used
        /// by undo, which restores tabs to their original position).
        static func insert(_ window: NSWindow, into anchor: NSWindow, at index: Int, select: Bool) {
            ensureWorkspaceObserver()
            let target = group(for: anchor)
            if let source = groupsByWindow[ObjectIdentifier(window)], source !== target {
                detachForTransfer(window)
            }
            groupsByWindow[ObjectIdentifier(window)] = target

            let clamped = max(0, min(index, target.windows.count))
            if WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier) == nil {
                WorkspaceStore.shared.assignTab(tabIdentifier: window.stableTabIdentifier, to: WorkspaceStore.shared.activeWorkspaceId, at: clamped)
            }

            guard !target.windows.contains(window) else { return }
            window.setFrame(anchor.frame, display: false)
            target.windows.insert(window, at: clamped)
            if target.windows.count > 1 { target.transitions.tabAppeared(window) }
            if select {
                target.select(window)
            } else {
                window.orderOut(nil)
            }
            Tako.TabBarController.refreshAll()
        }

        /// Drop a window from its group entirely, e.g. on close. Selecting
        /// its neighbor mirrors native tab-close behavior (the tab to the
        /// right takes focus, or the new last tab if it was rightmost).
        static func leave(_ window: NSWindow) {
            guard let group = groupsByWindow[ObjectIdentifier(window)] else { return }
            groupsByWindow.removeValue(forKey: ObjectIdentifier(window))

            guard let index = group.windows.firstIndex(of: window) else { return }
            let shownIndex = group.visibleWindows.firstIndex(of: window)
            group.windows.remove(at: index)
            if let shownIndex { group.transitions.tabClosed(window, at: shownIndex) }

            let isSelected = group.selectedWindow === window
            let visible = group.visibleWindows
            let next = index < visible.count ? visible[index] : visible.last

            if isSelected {
                if let next {
                    group.select(next)
                } else {
                    group.selectedWindow = nil
                }
            }

            // AppKit closes windows during a normal quit too. Those tabs are
            // detached for restoration, not explicitly closed by the user.
            if !SurfaceSession.appIsDetaching {
                WorkspaceStore.shared.removeTab(tabIdentifier: window.stableTabIdentifier)
            }
            group.lastSelectedWindowByWorkspace = group.lastSelectedWindowByWorkspace.filter { _, win in
                win !== window && group.windows.contains(win)
            }

            Tako.TabBarController.refreshAll()
        }

        /// Reorder a window within its own group (Cmd+Shift+[/]).
        static func move(_ window: NSWindow, to index: Int, in group: CustomTabGroup) {
            let visible = group.visibleWindows
            guard let currentVisibleIndex = visible.firstIndex(of: window) else { return }
            let clamped = max(0, min(index, visible.count - 1))
            guard clamped != currentVisibleIndex else { return }

            var newVisible = visible
            newVisible.remove(at: currentVisibleIndex)
            newVisible.insert(window, at: clamped)

            WorkspaceStore.shared.reorderTabs(
                in: WorkspaceStore.shared.activeWorkspaceId,
                newOrder: newVisible.map(\.stableTabIdentifier)
            )

            // Also keep windows array consistent
            if let current = group.windows.firstIndex(of: window) {
                group.windows.remove(at: current)
                let nextVisible = clamped + 1 < newVisible.count ? newVisible[clamped + 1] : nil
                let targetIdx = nextVisible.flatMap { group.windows.firstIndex(of: $0) } ?? group.windows.count
                group.windows.insert(window, at: targetIdx)
            }

            TabBarController.refreshAll()
        }

        /// Updates the internal windows order to match the specified order.
        func setWindowOrder(_ newOrder: [NSWindow]) {
            let currentSet = Set(windows.map(ObjectIdentifier.init))
            var ordered: [NSWindow] = []
            for w in newOrder where currentSet.contains(ObjectIdentifier(w)) {
                if !ordered.contains(w) {
                    ordered.append(w)
                }
            }
            for w in windows where !ordered.contains(w) {
                ordered.append(w)
            }
            self.windows = ordered
        }

    }
}
