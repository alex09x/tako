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
                    ((win.windowController as? TerminalController) ?? (win.delegate as? TerminalController))?.cancelPendingInitialPresentation()
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
                ((win.windowController as? TerminalController) ?? (win.delegate as? TerminalController))?.cancelPendingInitialPresentation()
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
            ((previous?.windowController as? TerminalController) ?? (previous?.delegate as? TerminalController))?.cancelPendingInitialPresentation()
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
