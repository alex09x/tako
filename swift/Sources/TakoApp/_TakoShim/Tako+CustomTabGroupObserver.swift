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

extension Tako.CustomTabGroup {
        static func ensureWorkspaceObserver() {
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
                            guard !isClosed(win) else { return false }
                            let tabId = win.stableTabIdentifier
                            if let ws = WorkspaceStore.shared.workspace(forTab: tabId) {
                                return ws.id == activeWsId
                            }
                            return activeWsId == WorkspaceStore.defaultWorkspaceId
                        }
                    }
                    if !hasWorkspaceWindow, !WorkspaceStore.shared.suppressEmptyWorkspaceCreation,
                       let app = (NSApp.delegate as? AppDelegate)?.tako {
                        // A workspace is a set of tabs, not a request for a
                        // second physical window. Reuse the window the user
                        // was in when entering this empty workspace.
                        let fromID = (notification.userInfo?["fromWorkspaceId"] as? UUID)
                            ?? WorkspaceStore.shared.recentTransitions.last?.fromId
                        let anchor: NSWindow? = {
                            if let key = NSApp.keyWindow, groupsByWindow[ObjectIdentifier(key)] != nil,
                               !isClosed(key),
                               fromID == nil || (WorkspaceStore.shared.workspace(forTab: key.stableTabIdentifier)?.id
                                   ?? WorkspaceStore.defaultWorkspaceId) == fromID { return key }
                            if let fromID, let remembered = WorkspaceStore.shared.workspace(for: fromID)?.activeTabIdentifier,
                               let window = allGroups.flatMap(\.windows).first(where: {
                                   !isClosed($0) && $0.stableTabIdentifier == remembered
                               }) { return window }
                            if let last = TerminalController.lastMain?.window,
                               groupsByWindow[ObjectIdentifier(last)] != nil, !isClosed(last),
                               fromID == nil || (WorkspaceStore.shared.workspace(forTab: last.stableTabIdentifier)?.id
                                   ?? WorkspaceStore.defaultWorkspaceId) == fromID { return last }
                            let groups = allGroups.filter { group in
                                group.windows.contains { window in
                                    guard !isClosed(window) else { return false }
                                    let ws = WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier)?.id
                                        ?? WorkspaceStore.defaultWorkspaceId
                                    return fromID == nil || ws == fromID
                                }
                            }
                            if groups.count == 1 { return groups[0].windows.first { !isClosed($0) } }
                            guard groups.isEmpty else { return nil }
                            let remaining = allGroups.filter { $0.windows.contains { !isClosed($0) } }
                            return remaining.count == 1 ? remaining[0].windows.first { !isClosed($0) } : nil
                        }()
                        let ctrl: TerminalController?
                        if let anchor, let parent = anchor.windowController as? TerminalController,
                           !(parent.fullscreenStyle?.isFullscreen == true && parent.fullscreenStyle?.supportsTabs == false) {
                            ctrl = TerminalController.newTab(app, from: anchor, select: true)
                        } else {
                            ctrl = TerminalController.newWindow(app)
                        }
                        guard let ctrl else { return }
                        if let win = ctrl.window {
                            ctrl.cancelPendingInitialPresentation()
                            let group = Tako.CustomTabGroup.group(for: win)
                            if group.syncWindowFrame, let frame = departingFrame {
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
                    Tako.CustomTabGroup.hideAllInactiveWindows()
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
}
