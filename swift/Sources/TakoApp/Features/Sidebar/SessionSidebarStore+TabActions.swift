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
import TakoKit

extension SessionSidebarStore {
    /// Selects a tab or child split pane corresponding to the sidebar item, switching workspace if needed.
    func selectTab(
        item: SessionSidebarItem,
        in window: NSWindow?,
        workspaceStore: WorkspaceStore = .shared
    ) {
        if let wsId = item.workspaceId {
            _ = workspaceStore.switchWorkspace(to: wsId)
            workspaceStore.setActiveTab(tabIdentifier: item.tabId, in: wsId)
        }
        // The tab may be in another window, its workspace's own: it is found
        // there, selected in its group, and that window comes forward.
        guard let target = sidebarWindow(tabId: item.tabId, around: window, workspaceStore: workspaceStore) else { return }
        let group = Tako.CustomTabGroup.group(for: target)
        group.select(target)
        if target !== window, !Tako.CustomTabGroup.suppressWindowOrderingForTesting {
            target.makeKeyAndOrderFront(nil)
        }
        let allTargetSurfaces = surfaces(in: target)
        if let sid = item.surfaceId {
            if let targetController = target.windowController as? BaseTerminalController,
               let targetSurface = targetController.surfaceTree.first(where: { $0.id == sid }) ?? allTargetSurfaces.first(where: { $0.id == sid }) {
                for s in allTargetSurfaces where s.id != sid {
                    s.focusDidChange(false)
                }
                targetController.focusedSurface = targetSurface
                ControlLayout.focus(targetSurface)
                targetSurface.focusDidChange(true)
            } else if let targetSurface = allTargetSurfaces.first(where: { $0.id == sid }) {
                for s in allTargetSurfaces where s.id != sid {
                    s.focusDidChange(false)
                }
                _ = target.makeFirstResponder(targetSurface)
                targetSurface.focusDidChange(true)
            }
        }
        objectWillChange.send()
    }

    /// Selects a workspace header in the sidebar tree and activates its active or first tab.
    func selectWorkspace(
        _ workspaceId: UUID,
        in window: NSWindow?,
        workspaceStore: WorkspaceStore = .shared
    ) {
        _ = workspaceStore.switchWorkspace(to: workspaceId)
        guard let ws = workspaceStore.workspace(for: workspaceId) else {
            objectWillChange.send()
            return
        }
        let targetId = ws.activeTabIdentifier ?? ws.tabIdentifiers.first
        if let targetId, let target = sidebarWindow(tabId: targetId, around: window, workspaceStore: workspaceStore) {
            Tako.CustomTabGroup.group(for: target).select(target)
            if target !== window, !Tako.CustomTabGroup.suppressWindowOrderingForTesting {
                target.makeKeyAndOrderFront(nil)
            }
        }
        objectWillChange.send()
    }

    /// Moves a tab up or down within its group.
    func moveTab(item: SessionSidebarItem, delta: Int, in window: NSWindow?) {
        guard let group = window.flatMap({ Tako.CustomTabGroup.group(for: $0) }) else { return }
        let newIndex = item.index + delta
        guard item.index >= 0 && item.index < group.windows.count,
              newIndex >= 0 && newIndex < group.windows.count else { return }
        let target = group.windows[item.index]
        Tako.CustomTabGroup.move(target, to: newIndex, in: group)
        objectWillChange.send()
    }

    /// Creates a new session tab in the target window's tab group.
    func createNewTab(in window: NSWindow?) {
        let target = window ?? NSApp?.keyWindow
        let controller = (target?.windowController as? TerminalController)
            ?? (target?.delegate as? TerminalController)
            ?? TerminalController.all.first
        if let controller {
            _ = TerminalController.newTab(controller.tako, from: controller.window ?? target)
        } else {
            _ = NSApp?.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: nil)
        }
        objectWillChange.send()
    }

    /// Prompts to rename a session tab from the sidebar.
    func promptRenameTab(item: SessionSidebarItem, in window: NSWindow?) {
        guard let target = sidebarWindow(tabId: item.tabId, around: window) else { return }
        Tako.CustomTabGroup.group(for: target).select(target)
        let controller = (target.windowController as? BaseTerminalController)
            ?? (target.delegate as? BaseTerminalController)
        controller?.promptTabTitle()
        objectWillChange.send()
    }

    /// Closes a session tab or split pane from the sidebar without tearing down sibling tabs.
    func closeTab(item: SessionSidebarItem, in window: NSWindow?) {
        // By its tab, not its place: the row may be a tab of another window.
        guard let target = sidebarWindow(tabId: item.tabId, around: window) else { return }
        if item.isChild,
           let sid = item.surfaceId,
           let baseController = (target.windowController as? BaseTerminalController)
            ?? (target.delegate as? BaseTerminalController),
           let pane = baseController.surfaceTree.first(where: { $0.id == sid }) {
            let needsConfirm = pane.needsConfirmClose || SubagentHierarchyStore.shared.hasChildren(pane.id)
            if needsConfirm {
                Tako.CustomTabGroup.group(for: target).select(target)
            }
            baseController.closeSurface(pane, withConfirmation: needsConfirm)
            objectWillChange.send()
            return
        }

        let controller = (target.windowController as? TerminalController)
            ?? (target.delegate as? TerminalController)
        if let controller {
            if controller.surfaceTree.contains(where: { $0.needsConfirmClose }) {
                Tako.CustomTabGroup.group(for: target).select(target)
            }
            controller.closeTab(nil)
        } else if target.styleMask.contains(.closable) {
            target.performClose(nil)
        } else {
            Tako.CustomTabGroup.close(target)
            target.close()
        }
        objectWillChange.send()
    }

    func surface(in window: NSWindow) -> Tako.SurfaceView? {
        Tako.surface(in: window)
    }

    func surfaces(in window: NSWindow) -> [Tako.SurfaceView] {
        Tako.surfaces(in: window)
    }
}
