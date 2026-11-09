/*
 * tako — A session row's menu actions (reference sidebar.js session menu)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// «New Terminal in Session», «Mark as Read» and «Reconnect»
/// for a sidebar row. Each goes to what Tako already does: a split in the
/// session's own tab, NotificationStore and the crab's unread mark, and a
/// lost session's own retry (the one Return runs in the pane).
extension SessionSidebarStore {
    /// The row's panes: every pane of a session row, the one pane of a pane row.
    func rowSurfaces(_ item: SessionSidebarItem, around window: NSWindow?,
                     workspaceStore: WorkspaceStore = .shared) -> [Tako.SurfaceView] {
        guard let tab = sidebarWindow(tabId: item.tabId, around: window, workspaceStore: workspaceStore) else { return [] }
        let all = surfaces(in: tab)
        if item.isChild, let id = item.surfaceId { return all.filter { $0.id == id } }
        return all
    }

    /// Unread notifications or the crab's unread mark on any of the row's panes.
    func rowHasUnread(_ item: SessionSidebarItem, around window: NSWindow?,
                      workspaceStore: WorkspaceStore = .shared) -> Bool {
        item.unreadCount > 0 || rowSurfaces(item, around: window, workspaceStore: workspaceStore).contains { $0.crab.unread }
    }

    /// Clears what waits unseen without focusing or changing any status.
    func markRowRead(_ item: SessionSidebarItem, around window: NSWindow?, workspaceStore: WorkspaceStore = .shared) {
        for surface in rowSurfaces(item, around: window, workspaceStore: workspaceStore) {
            NotificationStore.shared.markRead(surfaceId: surface.id)
            if surface.crab.unread { surface.crab.unread = false }
        }
        objectWillChange.send()
    }

    /// Panes whose session was lost and that wait to try it again.
    func rowCanReconnect(_ item: SessionSidebarItem, around window: NSWindow?,
                         workspaceStore: WorkspaceStore = .shared) -> Bool {
        rowSurfaces(item, around: window, workspaceStore: workspaceStore).contains { $0.sessionRetry != nil }
    }

    func reconnectRow(_ item: SessionSidebarItem, around window: NSWindow?, workspaceStore: WorkspaceStore = .shared) {
        for surface in rowSurfaces(item, around: window, workspaceStore: workspaceStore) { surface.sessionRetry?() }
        objectWillChange.send()
    }

    /// A new terminal beside the session's focused one, in that session's tab.
    func newTerminal(inSession item: SessionSidebarItem, around window: NSWindow?,
                     workspaceStore: WorkspaceStore = .shared) {
        selectTab(item: item, in: window, workspaceStore: workspaceStore)
        guard let tab = sidebarWindow(tabId: item.tabId, around: window, workspaceStore: workspaceStore),
              let controller = tab.windowController as? BaseTerminalController else { return }
        controller.splitRight(tab)
        objectWillChange.send()
    }
}
