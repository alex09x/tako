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

/// A drag is accepted only by the instance that started it. Text from other
/// apps or another Tako process cannot silently move one of this app's tabs.
enum SidebarTabTransfer {
    static let processNonce = UUID()
    static func encode(_ tabID: String) -> String {
        "tako-sidebar:\(processNonce.uuidString):\(tabID)"
    }
    static func decode(_ payload: String) -> String? {
        let prefix = "tako-sidebar:\(processNonce.uuidString):"
        guard payload.hasPrefix(prefix) else { return nil }
        let tabID = String(payload.dropFirst(prefix.count))
        return tabID.isEmpty ? nil : tabID
    }
}

extension SessionSidebarStore {
    func canMoveTabToWindow(_ tabID: String, around window: NSWindow?,
                            workspaceStore: WorkspaceStore = .shared) -> Bool {
        guard let window, let target = sidebarWindow(tabId: tabID, around: window, workspaceStore: workspaceStore),
              target !== window, !Tako.CustomTabGroup.isClosed(target),
              workspaceStore.workspace(forTab: tabID)?.id == workspaceStore.workspace(forTab: window.stableTabIdentifier)?.id else { return false }
        let source = Tako.CustomTabGroup.group(for: target)
        let destination = Tako.CustomTabGroup.group(for: window)
        return source !== destination && (source.windows.count == 1 || destination.windows.count == 1)
    }

    @discardableResult
    func moveTabToWindow(_ tabID: String, around window: NSWindow?,
                         workspaceStore: WorkspaceStore = .shared) -> Bool {
        guard canMoveTabToWindow(tabID, around: window, workspaceStore: workspaceStore), let window,
              let target = sidebarWindow(tabId: tabID, around: window, workspaceStore: workspaceStore) else { return false }
        if Tako.CustomTabGroup.group(for: target).windows.count == 1 {
            Tako.CustomTabGroup.join(target, to: window, select: true)
        } else {
            // Keep an existing multi-tab group intact when the current
            // window is the standalone one.
            Tako.CustomTabGroup.join(window, to: target, select: false)
            Tako.CustomTabGroup.group(for: target).select(target)
            if !Tako.CustomTabGroup.suppressWindowOrderingForTesting { target.makeKeyAndOrderFront(nil) }
        }
        objectWillChange.send()
        return true
    }

    /// Move the existing tab window, not its processes or its pane tree.
    @discardableResult
    func moveTab(_ tabID: String, to workspaceID: UUID, around window: NSWindow?,
                 workspaceStore: WorkspaceStore = .shared) -> Bool {
        guard workspaceStore.workspace(for: workspaceID) != nil,
              let target = sidebarWindow(tabId: tabID, around: window, workspaceStore: workspaceStore),
              !Tako.CustomTabGroup.isClosed(target) else { return false }
        if workspaceStore.workspace(forTab: tabID)?.id == workspaceID { return true }
        let anchor = destinationAnchor(for: target, workspaceID: workspaceID, store: workspaceStore)
        workspaceStore.assignTab(tabIdentifier: tabID, to: workspaceID)
        if let anchor { Tako.CustomTabGroup.join(target, to: anchor, select: false) }
        workspaceStore.setActiveTab(tabIdentifier: tabID, in: workspaceID)
        guard workspaceStore.switchWorkspace(to: workspaceID) else { return false }
        Tako.CustomTabGroup.group(for: target).select(target)
        if !Tako.CustomTabGroup.suppressWindowOrderingForTesting { target.makeKeyAndOrderFront(nil) }
        objectWillChange.send()
        return true
    }

    private func destinationAnchor(for window: NSWindow, workspaceID: UUID, store: WorkspaceStore) -> NSWindow? {
        if let controller = window.windowController as? TerminalController,
           controller.fullscreenStyle?.isFullscreen == true, controller.fullscreenStyle?.supportsTabs == false { return nil }
        let source = Tako.CustomTabGroup.group(for: window)
        let groups = Tako.CustomTabGroup.allGroups.filter { group in
            if let controller = group.selectedWindow?.windowController as? TerminalController,
               controller.fullscreenStyle?.isFullscreen == true, controller.fullscreenStyle?.supportsTabs == false { return false }
            return group.windows.contains { candidate in
                !Tako.CustomTabGroup.isClosed(candidate) &&
                    (store.workspace(forTab: candidate.stableTabIdentifier)?.id ?? WorkspaceStore.defaultWorkspaceId) == workspaceID
            }
        }
        // The tab already shares a physical window with this workspace.
        if groups.contains(where: { $0 === source }) { return nil }
        if let selected = store.workspace(for: workspaceID)?.activeTabIdentifier,
           (store.workspace(forTab: selected)?.id ?? WorkspaceStore.defaultWorkspaceId) == workspaceID,
           let window = groups.flatMap(\.windows).first(where: { !Tako.CustomTabGroup.isClosed($0) && $0.stableTabIdentifier == selected }) { return window }
        // Multiple windows without a remembered selection are ambiguous.
        guard groups.count == 1 else { return nil }
        return groups[0].windows.first {
            !Tako.CustomTabGroup.isClosed($0) &&
                (store.workspace(forTab: $0.stableTabIdentifier)?.id ?? WorkspaceStore.defaultWorkspaceId) == workspaceID
        }
    }
}

struct SidebarWorkspaceDropTarget: View {
    let group: SessionSidebarWorkspaceGroup
    let onToggleCollapse: () -> Void
    let onSelectWorkspace: () -> Void
    let onMove: (String, UUID) -> Bool
    @State private var targeted = false

    var body: some View {
        SessionSidebarWorkspaceHeaderView(group: group, onToggleCollapse: onToggleCollapse,
                                          onSelectWorkspace: onSelectWorkspace)
            .background {
                if targeted {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: Tako.LivingTokens.ember).opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: Tako.LivingTokens.ember).opacity(0.7), lineWidth: 1))
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard items.count == 1, let drag = items.first, let tabID = SidebarTabTransfer.decode(drag) else { return false }
                return onMove(tabID, group.id)
            } isTargeted: { targeted = $0 }
    }
}

struct SidebarWorkspaceMoveModifier: ViewModifier {
    let item: SessionSidebarItem
    let workspaces: [Workspace]
    let onMove: (String, UUID) -> Bool
    let canMoveToWindow: () -> Bool
    let onMoveToWindow: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if item.isChild {
            menu(content)
        } else {
            menu(content.draggable(SidebarTabTransfer.encode(item.tabId))
                .help("Drag this session to a workspace"))
        }
    }

    private func menu<Content: View>(_ content: Content) -> some View {
        content.contextMenu {
            if canMoveToWindow() {
                Button(item.isChild ? "Move Tab to This Window" : "Move to This Window", action: onMoveToWindow)
            }
            Menu(item.isChild ? "Move Tab to Workspace" : "Move to Workspace") {
                ForEach(workspaces) { workspace in
                    Button(workspace.name) { _ = onMove(item.tabId, workspace.id) }
                        .disabled(workspace.id == item.workspaceId)
                }
            }
        }
    }
}
