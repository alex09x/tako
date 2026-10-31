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
        private(set) var windows: [NSWindow] = []
        private(set) var selectedWindow: NSWindow?
        /// What the group's tab strips are moving (Tako+TabStripTransitions.swift).
        let transitions = TabStripTransitions()
        private weak var pendingOrderOutWindow: NSWindow?
        private var lastSelectedWindowByWorkspace: [UUID: NSWindow] = [:]
        private(set) var focusGeneration: Int = 0
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

        private static var groupsByWindow: [ObjectIdentifier: CustomTabGroup] = [:]
        private static var workspaceObserverInstalled = false

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

        private static func ensureWorkspaceObserver() {
            guard !workspaceObserverInstalled else { return }
            workspaceObserverInstalled = true
            NotificationCenter.default.addObserver(
                forName: .takoWorkspaceDidChange,
                object: nil,
                queue: nil
            ) { notification in
                MainActor.assumeIsolated {
                    // Capture departing active window frame from the departing workspace before selection is cleared or windows hidden.
                    let departingFrame: NSRect? = {
                        let departingWsId = (notification.userInfo?["fromWorkspaceId"] as? UUID)
                            ?? WorkspaceStore.shared.recentTransitions.last?.fromId

                        let belongsToDeparting: (NSWindow) -> Bool = { win in
                            guard let departingWsId else { return true }
                            let tabId = win.stableTabIdentifier
                            if let ws = WorkspaceStore.shared.workspace(forTab: tabId) {
                                return ws.id == departingWsId
                            }
                            return departingWsId == WorkspaceStore.defaultWorkspaceId
                        }

                        // 1. If key window belongs to departing workspace, use its live frame.
                        if let keyWin = NSApp.keyWindow, belongsToDeparting(keyWin), groupsByWindow[ObjectIdentifier(keyWin)] != nil {
                            return keyWin.frame
                        }

                        // 2. Check group's remembered window for departing workspace if visible.
                        if let departingWsId {
                            for group in allGroups {
                                if let remembered = group.lastSelectedWindowByWorkspace[departingWsId],
                                   remembered.isVisible,
                                   belongsToDeparting(remembered) {
                                    return remembered.frame
                                }
                            }
                        }

                        // 3. Check group's selected visible window belonging to departing workspace.
                        for group in allGroups {
                            if let sel = group.selectedWindow, sel.isVisible, belongsToDeparting(sel) {
                                return sel.frame
                            }
                        }

                        // 4. Check any visible window belonging to departing workspace.
                        for group in allGroups {
                            for win in group.windows where win.isVisible && belongsToDeparting(win) {
                                return win.frame
                            }
                        }

                        // 5. Fall back to any departing window even if hidden.
                        for group in allGroups {
                            if let sel = group.selectedWindow, belongsToDeparting(sel) {
                                return sel.frame
                            }
                        }
                        for group in allGroups {
                            for win in group.windows where belongsToDeparting(win) {
                                return win.frame
                            }
                        }

                        // 6. Fall back to frontmost Tako window or lastActiveWindowFrame.
                        if let keyWin = NSApp.keyWindow, groupsByWindow[ObjectIdentifier(keyWin)] != nil {
                            return keyWin.frame
                        }
                        return lastActiveWindowFrame
                    }()
                    if let departingFrame {
                        lastActiveWindowFrame = departingFrame
                    }

                    let activeWsId = WorkspaceStore.shared.activeWorkspaceId
                    let hasWorkspaceWindow = allGroups.contains { group in
                        group.windows.contains { win in
                            let tabId = win.stableTabIdentifier
                            if let ws = WorkspaceStore.shared.workspace(forTab: tabId) {
                                return ws.id == activeWsId
                            }
                            return activeWsId == WorkspaceStore.defaultWorkspaceId
                        }
                    }
                    if !hasWorkspaceWindow, let app = (NSApp.delegate as? AppDelegate)?.tako {
                        let ctrl = TerminalController.newWindow(app)
                        if let win = ctrl.window {
                            let group = CustomTabGroup.group(for: win)
                            if group.syncWindowFrame, let frame = departingFrame {
                                ctrl.cancelPendingInitialPresentation()
                                win.setFrame(frame, display: true)
                                Self.lastActiveWindowFrame = frame
                            }
                            if !suppressWindowOrderingForTesting {
                                win.makeKeyAndOrderFront(nil)
                                NSApp.activate(ignoringOtherApps: true)
                            }
                            let focused = ctrl.focusedSurface ?? ctrl.surfaceTree.first
                            ctrl.focusedSurface = focused
                            if let focused {
                                win.makeFirstResponder(focused)
                            }
                        }
                    }
                    // Pass 1: Hide all inactive windows across all groups and the app first,
                    // so ordering out an inactive window cannot resign a newly activated key window.
                    CustomTabGroup.hideAllInactiveWindows()
                    for group in allGroups {
                        group.hideInactiveWindows()
                    }

                    // Pass 2: Sync active windows for each group with the captured departing frame.
                    for group in allGroups {
                        group.syncWithActiveWorkspace(inheritedFrame: departingFrame)
                    }

                    // Pass 3: Present and focus the active window of the active workspace.
                    let activeWs = WorkspaceStore.shared.activeWorkspace
                    let activeGroup = allGroups.first { group in
                        group.visibleWindows.contains { $0.stableTabIdentifier == activeWs.activeTabIdentifier }
                    } ?? allGroups.first { !$0.visibleWindows.isEmpty }

                    if let activeGroup,
                       let target = activeGroup.selectedWindow {
                        if !suppressWindowOrderingForTesting {
                            if !target.isMiniaturized {
                                target.makeKeyAndOrderFront(nil)
                                NSApp.activate(ignoringOtherApps: true)
                            }
                        }
                        let controller = (target.windowController as? TerminalController) ??
                            (target.delegate as? TerminalController) ??
                            TerminalController.all.first { $0.window === target }
                        let focused = controller?.focusedSurface ?? controller?.surfaceTree.first
                        controller?.focusedSurface = focused
                        if let focused {
                            target.makeFirstResponder(focused)
                        }
                    }

                    Tako.TabBarController.refreshAll()
                }
            }
            NotificationCenter.default.addObserver(
                forName: .takoTabsDidChange,
                object: nil,
                queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    Tako.TabBarController.refreshAll()
                }
            }
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: nil
            ) { notif in
                MainActor.assumeIsolated {
                    guard let win = notif.object as? NSWindow,
                          let group = groupsByWindow[ObjectIdentifier(win)],
                          win !== group.pendingOrderOutWindow else { return }
                    lastActiveWindowFrame = win.frame
                    let tabId = win.stableTabIdentifier
                    let wsId = WorkspaceStore.shared.workspace(forTab: tabId)?.id ?? WorkspaceStore.shared.activeWorkspaceId
                    group.recordSelection(win, for: wsId)
                    WorkspaceStore.shared.setActiveTab(tabIdentifier: tabId, in: wsId)
                }
            }
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: nil,
                queue: nil
            ) { notif in
                MainActor.assumeIsolated {
                    guard let win = notif.object as? NSWindow,
                          groupsByWindow[ObjectIdentifier(win)] != nil else { return }
                    lastActiveWindowFrame = win.frame
                }
            }
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: nil,
                queue: nil
            ) { notif in
                MainActor.assumeIsolated {
                    guard let win = notif.object as? NSWindow,
                          groupsByWindow[ObjectIdentifier(win)] != nil else { return }
                    lastActiveWindowFrame = win.frame
                }
            }
            NotificationCenter.default.addObserver(
                forName: .takoConfigDidChange,
                object: nil,
                queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    if let keyWin = NSApp.keyWindow, groupsByWindow[ObjectIdentifier(keyWin)] != nil {
                        lastActiveWindowFrame = keyWin.frame
                    }
                }
            }
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
        private static let closedWindows = NSHashTable<NSWindow>.weakObjects()

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

        /// Add `window` to the same group as `anchor`, dropping it from
        /// whatever single-window group it was in on its own (every window
        /// starts in one via `group(for:)` the moment anything asks).
        static func join(_ window: NSWindow, to anchor: NSWindow, select: Bool) {
            ensureWorkspaceObserver()
            let target = group(for: anchor)
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

        /// Hide any terminal windows across the application that do not belong to the active workspace.
        static func hideAllInactiveWindows() {
            let activeWs = WorkspaceStore.shared.activeWorkspace
            let isDefault = activeWs.id == WorkspaceStore.defaultWorkspaceId

            for win in NSApp.windows {
                if String(describing: type(of: win)).contains("Menu") {
                    win.orderOut(nil)
                    continue
                }
                guard (win.windowController as? TerminalController) != nil || (win.delegate as? TerminalController) != nil else {
                    continue
                }
                let tabId = win.stableTabIdentifier
                let belongsToActive: Bool
                if let ws = WorkspaceStore.shared.workspace(forTab: tabId) {
                    belongsToActive = ws.id == activeWs.id
                } else {
                    belongsToActive = isDefault
                }
                if !belongsToActive {
                    if let sheet = win.attachedSheet { sheet.orderOut(nil) }
                    for child in win.childWindows ?? [] { child.orderOut(nil) }
                    win.orderOut(nil)
                }
            }
        }

        /// Hide any windows in this group that do not belong to the active workspace.
        func hideInactiveWindows() {
            let visible = visibleWindows
            for win in windows where !visible.contains(win) {
                if let sheet = win.attachedSheet {
                    sheet.orderOut(nil)
                }
                for child in win.childWindows ?? [] {
                    child.orderOut(nil)
                }
                win.orderOut(nil)
            }
            for w in NSApp.windows where String(describing: type(of: w)).contains("Menu") {
                w.orderOut(nil)
            }
        }

        func select(_ window: NSWindow) {
            guard windows.contains(window), !Self.closedWindows.contains(window) else { return }
            // Selecting the tab that is already chosen starts nothing new, so
            // it must not cancel the pending order-out of the one it replaced:
            // a sidebar click selects, then presenting the pane selects again,
            // and every tab clicked away from used to stay on screen beneath.
            if selectedWindow !== window { focusGeneration += 1 }
            let gen = focusGeneration
            let reflowSurfaces: () -> Void = { [weak self, weak window] in
                guard let self, let window, self.focusGeneration == gen else { return }
                guard window.isVisible, self.selectedWindow === window, self.visibleWindows.contains(window) else { return }
                if let controller = (window.windowController as? TerminalController) ?? (window.delegate as? TerminalController) {
                    controller.reflowSurfaces(forcePtyResize: true)
                    let focused = controller.focusedSurface ?? controller.surfaceTree.first
                    controller.focusedSurface = focused
                    if let focused {
                        window.makeFirstResponder(focused)
                    }
                }
            }
            guard selectedWindow !== window else {
                if window.isVisible {
                    window.makeKeyAndOrderFront(nil)
                    Tako.TabBarController.clearTitlebarBackground(in: window)
                }
                Self.lastActiveWindowFrame = window.frame
                let wsId = WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier)?.id ?? WorkspaceStore.shared.activeWorkspaceId
                lastSelectedWindowByWorkspace[wsId] = window
                WorkspaceStore.shared.setActiveTab(tabIdentifier: window.stableTabIdentifier, in: wsId)
                reflowSurfaces()
                return
            }
            let previous = selectedWindow
            transitions.selectionMoved(from: previous)
            selectedWindow = window
            pendingOrderOutWindow = previous
            Self.lastActiveWindowFrame = window.frame
            if previous?.isVisible == true || window.isVisible {
                window.setFrame(previous?.frame ?? window.frame, display: false)
                window.order(.above, relativeTo: previous?.windowNumber ?? 0)
                window.makeKeyAndOrderFront(nil)
                Tako.TabBarController.clearTitlebarBackground(in: window)
                NSApp.activate(ignoringOtherApps: true)
                CATransaction.flush()
                DispatchQueue.main.async { [weak self, weak previous, weak window] in
                    guard let self, self.focusGeneration == gen else { return }
                    self.pendingOrderOutWindow = nil
                    if let window {
                        self.selectedWindow = window
                    }
                    if let previous, previous !== self.selectedWindow {
                        previous.orderOut(nil)
                    }
                    Tako.TabBarController.refreshAll()
                }
            }

            let wsId = WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier)?.id ?? WorkspaceStore.shared.activeWorkspaceId
            lastSelectedWindowByWorkspace[wsId] = window
            WorkspaceStore.shared.setActiveTab(tabIdentifier: window.stableTabIdentifier, in: wsId)

            reflowSurfaces()
            DispatchQueue.main.async {
                reflowSurfaces()
            }
            Tako.TabBarController.refreshAll()
        }

        /// Synchronize selected window and orderOut non-visible windows when active workspace changes.
        func syncWithActiveWorkspace(inheritedFrame: NSRect? = nil) {
            hideInactiveWindows()

            focusGeneration += 1
            let gen = focusGeneration
            let visible = visibleWindows
            let activeWs = WorkspaceStore.shared.activeWorkspace

            // Find target window to show for this workspace
            var targetWindow: NSWindow?
            if let activeTabId = activeWs.activeTabIdentifier {
                targetWindow = visible.first { $0.stableTabIdentifier == activeTabId }
            }
            if targetWindow == nil, let remembered = lastSelectedWindowByWorkspace[activeWs.id], visible.contains(remembered) {
                targetWindow = remembered
            }
            if targetWindow == nil, let current = selectedWindow, visible.contains(current) {
                targetWindow = current
            }
            if targetWindow == nil {
                targetWindow = visible.first
            }

            if let target = targetWindow {
                lastSelectedWindowByWorkspace[activeWs.id] = target
                let reflowTarget: () -> Void = { [weak self, weak target] in
                    guard let self, let target, self.focusGeneration == gen else { return }
                    guard target.isVisible, self.selectedWindow === target, self.visibleWindows.contains(target) else { return }

                    let controller = (target.windowController as? TerminalController) ??
                        (target.delegate as? TerminalController) ??
                        TerminalController.all.first { $0.window === target }
                    if let controller {
                        for surface in controller.surfaceTree {
                            surface.reflowToCurrentBounds(forcePtyResize: true)
                        }
                        let focused = controller.focusedSurface ?? controller.surfaceTree.first
                        controller.focusedSurface = focused
                        if let focused {
                            target.makeFirstResponder(focused)
                        }
                    }
                }
                let prev = selectedWindow
                let controller = (target.windowController as? TerminalController) ??
                    (target.delegate as? TerminalController) ??
                    TerminalController.all.first { $0.window === target }
                if selectedWindow !== target {
                    selectedWindow = target
                    let frameToSync = inheritedFrame ?? prev?.frame ?? Self.lastActiveWindowFrame
                    if syncWindowFrame, let frame = frameToSync {
                        controller?.cancelPendingInitialPresentation()
                        target.setFrame(frame, display: true)
                        Self.lastActiveWindowFrame = frame
                    }
                    if !Self.suppressWindowOrderingForTesting {
                        if !target.isMiniaturized {
                            target.orderFront(nil)
                        }
                        if prev !== target {
                            prev?.orderOut(nil)
                        }
                    }
                } else {
                    let frameToSync = inheritedFrame ?? Self.lastActiveWindowFrame
                    if syncWindowFrame, let frame = frameToSync {
                        controller?.cancelPendingInitialPresentation()
                        target.setFrame(frame, display: true)
                        Self.lastActiveWindowFrame = frame
                    }
                    if !Self.suppressWindowOrderingForTesting {
                        if !target.isMiniaturized {
                            target.orderFront(nil)
                        }
                    }
                }
                for sibling in windows where sibling !== target {
                    if let sheet = sibling.attachedSheet { sheet.orderOut(nil) }
                    for child in sibling.childWindows ?? [] { child.orderOut(nil) }
                    sibling.orderOut(nil)
                }
                reflowTarget()
                DispatchQueue.main.async {
                    reflowTarget()
                }
            } else {
                selectedWindow = nil
                for win in windows {
                    if let sheet = win.attachedSheet { sheet.orderOut(nil) }
                    for child in win.childWindows ?? [] { child.orderOut(nil) }
                    win.orderOut(nil)
                }
            }

            hideInactiveWindows()
        }

        /// Keep every tab's frame in sync so a hidden one is never shown
        /// stale geometry when it's brought forward -- called on resize of
        /// whichever window is currently selected.
        func syncFrame(from window: NSWindow) {
            guard selectedWindow === window else { return }
            Self.lastActiveWindowFrame = window.frame
            let winWs = WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier)?.id ?? WorkspaceStore.defaultWorkspaceId
            for sibling in windows where sibling !== window {
                let siblingWs = WorkspaceStore.shared.workspace(forTab: sibling.stableTabIdentifier)?.id ?? WorkspaceStore.defaultWorkspaceId
                // Preserve independent workspace geometry on resize when disabled
                if siblingWs != winWs && !syncWindowFrame {
                    continue
                }
                sibling.setFrame(window.frame, display: false)
                if let controller = sibling.windowController as? TerminalController {
                    controller.reflowSurfaces(forcePtyResize: true)
                }
            }
        }
    }
}
