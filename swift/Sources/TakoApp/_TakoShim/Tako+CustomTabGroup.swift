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
        /// Monotonically increasing generation to invalidate stale focus/reflow callbacks.
        private var focusGeneration: Int = 0

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
            let activeWs = WorkspaceStore.shared.activeWorkspace
            let activeTabIds = activeWs.tabIdentifiers

            // Any window in this group assigned to the active workspace (or default if unassigned)
            let matching = windows.filter { win in
                let ws = WorkspaceStore.shared.workspace(forTab: win.stableTabIdentifier)
                if let ws {
                    return ws.id == activeWs.id
                }
                // Unassigned windows belong to the default workspace
                return activeWs.id == WorkspaceStore.defaultWorkspaceId
            }

            if activeTabIds.isEmpty {
                return matching
            }

            return matching.sorted { a, b in
                let idxA = activeTabIds.firstIndex(of: a.stableTabIdentifier) ?? Int.max
                let idxB = activeTabIds.firstIndex(of: b.stableTabIdentifier) ?? Int.max
                if idxA != idxB { return idxA < idxB }
                let origA = windows.firstIndex(of: a) ?? 0
                let origB = windows.firstIndex(of: b) ?? 0
                return origA < origB
            }
        }

        private static func ensureWorkspaceObserver() {
            guard !workspaceObserverInstalled else { return }
            workspaceObserverInstalled = true
            NotificationCenter.default.addObserver(
                forName: .takoWorkspaceDidChange,
                object: nil,
                queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    let activeWsId = WorkspaceStore.shared.activeWorkspaceId
                    let assignedTabs = WorkspaceStore.shared.workspace(for: activeWsId)?.tabIdentifiers ?? []
                    let hasWorkspaceWindow = allGroups.contains { group in
                        group.windows.contains { assignedTabs.contains($0.stableTabIdentifier) }
                    }
                    if !hasWorkspaceWindow, let app = (NSApp.delegate as? AppDelegate)?.tako {
                        let ctrl = TerminalController.newWindow(app)
                        if let win = ctrl.window {
                            _ = CustomTabGroup.group(for: win)
                            win.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
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

                    // Pass 2: Sync active windows for each group.
                    for group in allGroups {
                        group.syncWithActiveWorkspace()
                    }

                    // Pass 3: Present and focus the active window of the active workspace.
                    let activeWs = WorkspaceStore.shared.activeWorkspace
                    let activeGroup = allGroups.first { group in
                        group.visibleWindows.contains { $0.stableTabIdentifier == activeWs.activeTabIdentifier }
                    } ?? allGroups.first { !$0.visibleWindows.isEmpty }

                    if let activeGroup,
                       let target = activeGroup.selectedWindow {
                        target.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
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
        }

        /// The group a window belongs to, creating a fresh single-window
        /// group the first time a window is asked about.
        static func group(for window: NSWindow) -> CustomTabGroup {
            ensureWorkspaceObserver()
            if let existing = groupsByWindow[ObjectIdentifier(window)] {
                return existing
            }
            let group = CustomTabGroup()
            group.windows = [window]
            group.selectedWindow = window
            groupsByWindow[ObjectIdentifier(window)] = group

            // Assign window to active workspace if unassigned
            if WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier) == nil {
                WorkspaceStore.shared.assignTab(tabIdentifier: window.stableTabIdentifier, to: WorkspaceStore.shared.activeWorkspaceId)
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
            group.windows.remove(at: index)

            let isSelected = group.selectedWindow === window
            let visible = group.visibleWindows
            let next = index < visible.count ? visible[index] : visible.last

            WorkspaceStore.shared.removeTab(tabIdentifier: window.stableTabIdentifier)

            if isSelected {
                if let next {
                    group.select(next)
                } else {
                    group.selectedWindow = nil
                }
            } else {
                Tako.TabBarController.refreshAll()
            }
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
            guard windows.contains(window) else { return }
            focusGeneration += 1
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
                }
                reflowSurfaces()
                return
            }
            let previous = selectedWindow
            selectedWindow = window
            if previous?.isVisible == true || window.isVisible {
                window.setFrame(previous?.frame ?? window.frame, display: false)
                window.makeKeyAndOrderFront(nil)
                previous?.orderOut(nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            if let ws = WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier) {
                WorkspaceStore.shared.setActiveTab(tabIdentifier: window.stableTabIdentifier, in: ws.id)
            }

            reflowSurfaces()
            DispatchQueue.main.async {
                reflowSurfaces()
            }
            Tako.TabBarController.refreshAll()
        }

        /// Synchronize selected window and orderOut non-visible windows when active workspace changes.
        func syncWithActiveWorkspace() {
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
            if targetWindow == nil {
                targetWindow = visible.first
            }

            if let target = targetWindow {
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
                if selectedWindow !== target {
                    let prev = selectedWindow
                    selectedWindow = target
                    target.setFrame(prev?.frame ?? target.frame, display: false)
                    target.makeKeyAndOrderFront(nil)
                    if prev !== target {
                        prev?.orderOut(nil)
                    }
                } else {
                    target.makeKeyAndOrderFront(nil)
                }
                for sibling in windows where sibling !== target {
                    if let sheet = sibling.attachedSheet { sheet.orderOut(nil) }
                    for child in sibling.childWindows ?? [] { child.orderOut(nil) }
                    sibling.orderOut(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
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
            for sibling in windows where sibling !== window {
                sibling.setFrame(window.frame, display: false)
                if let controller = sibling.windowController as? TerminalController {
                    controller.reflowSurfaces(forcePtyResize: true)
                }
            }
        }
    }
}
