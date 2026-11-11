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
import SwiftUI

extension SessionSidebarView {
    /// One session or pane row, in the style the settings ask for, with its
    /// menu, drag and in-place rename.
    func sessionRow(_ item: SessionSidebarItem, flatItems: [SessionSidebarItem],
                    workspace: SidebarStatusBucket.WorkspaceBadge?) -> some View {
        let flatIdx = flatItems.firstIndex(where: { $0.id == item.id }) ?? 0
        let preferences = presentation.preferences
        return SessionSidebarRowView(
            item: item, index: flatIdx, selectedIndex: showsArrowCursor ? selectedIndex : -1,
            targetWindow: targetWindow, editingItemId: $editingItemId,
            editingDescriptionText: $editingDescriptionText, isPresented: $isPresented,
            reduceMotion: animState.reduceMotion, motionPaused: motionPaused,
            onSelect: {
                selectedIndex = flatIdx
                showsArrowCursor = false
                store.selectTab(item: item, in: targetWindow, workspaceStore: workspaceStore)
            },
            onClose: { store.closeTab(item: item, in: targetWindow) },
            style: preferences.sidebarStyle, workspace: workspace,
            textSize: preferences.sidebarTextSize, secondaryText: preferences.sidebarSecondaryText
        )
        .modifier(SidebarWorkspaceMoveModifier(item: item, workspaces: workspaceStore.workspaces,
            onMove: { store.moveTab($0, to: $1, around: targetWindow, workspaceStore: workspaceStore) },
            canMoveToWindow: { store.canMoveTabToWindow(item.tabId, around: targetWindow, workspaceStore: workspaceStore) },
            onMoveToWindow: { _ = store.moveTabToWindow(item.tabId, around: targetWindow, workspaceStore: workspaceStore) },
            onNewSession: { store.createNewTab(in: targetWindow) },
            // Only a row with a name of its own to change offers renaming.
            onRename: store.canRename(item, around: targetWindow)
                ? { SidebarRenameEditor.shared.begin(item, in: targetWindow, store: store) } : nil,
            hasOwnName: { store.ownName(of: item, around: targetWindow) != nil },
            onAutomaticName: { SidebarRenameEditor.shared.useAutomaticName(item, in: targetWindow, store: store) },
            onClose: { store.closeTab(item: item, in: targetWindow) },
            onNewTerminal: { store.newTerminal(inSession: item, around: targetWindow, workspaceStore: workspaceStore) },
            hasUnread: { store.rowHasUnread(item, around: targetWindow, workspaceStore: workspaceStore) },
            onMarkRead: { store.markRowRead(item, around: targetWindow, workspaceStore: workspaceStore) },
            canReconnect: { store.rowCanReconnect(item, around: targetWindow, workspaceStore: workspaceStore) },
            onReconnect: { store.reconnectRow(item, around: targetWindow, workspaceStore: workspaceStore) }))
    }

    /// F2 renames the row under the arrow-key cursor, in place.
    static let renameKey = KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
}
