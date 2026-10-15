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
        guard let group = window.flatMap({ Tako.CustomTabGroup.group(for: $0) }) else { return }
        let target: NSWindow? = group.windows.first(where: { $0.stableTabIdentifier == item.tabId })
            ?? ((item.index >= 0 && item.index < group.windows.count) ? group.windows[item.index] : nil)
        guard let target else { return }

        group.select(target)
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
        guard let ws = workspaceStore.workspace(for: workspaceId),
              let group = window.flatMap({ Tako.CustomTabGroup.group(for: $0) }) else {
            objectWillChange.send()
            return
        }
        let targetId = ws.activeTabIdentifier ?? ws.tabIdentifiers.first
        if let targetId,
           let target = group.windows.first(where: { $0.stableTabIdentifier == targetId }) {
            group.select(target)
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

    /// Closes a tab from the sidebar.
    func closeTab(item: SessionSidebarItem, in window: NSWindow?) {
        guard let group = window.flatMap({ Tako.CustomTabGroup.group(for: $0) }) else { return }
        if item.index >= 0 && item.index < group.windows.count {
            let target = group.windows[item.index]
            target.performClose(nil)
            objectWillChange.send()
        }
    }

    func surface(in window: NSWindow) -> Tako.SurfaceView? {
        func find(_ view: NSView) -> Tako.SurfaceView? {
            if let s = view as? Tako.SurfaceView { return s }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    func surfaces(in window: NSWindow) -> [Tako.SurfaceView] {
        func collect(_ view: NSView, into list: inout [Tako.SurfaceView]) {
            if let surface = view as? Tako.SurfaceView {
                list.append(surface)
            }
            for sub in view.subviews {
                collect(sub, into: &list)
            }
        }
        var list: [Tako.SurfaceView] = []
        if let content = window.contentView {
            collect(content, into: &list)
        }
        return list
    }
}
