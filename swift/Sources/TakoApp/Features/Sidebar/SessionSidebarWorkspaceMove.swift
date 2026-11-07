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
                 workspaceStore: WorkspaceStore = .shared,
                 appearanceStore: ScopedAppearanceStore = .shared) -> Bool {
        guard workspaceStore.workspace(for: workspaceID) != nil,
              let target = sidebarWindow(tabId: tabID, around: window, workspaceStore: workspaceStore),
              !Tako.CustomTabGroup.isClosed(target) else { return false }
        if workspaceStore.workspace(forTab: tabID)?.id == workspaceID { return true }
        let source = workspaceStore.workspace(forTab: tabID)?.id ?? workspaceStore.activeWorkspaceId
        let panes = (target.windowController as? BaseTerminalController).map { Array($0.surfaceTree) } ?? Tako.surfaces(in: target)
        do { try appearanceStore.preserveWorkspaceStyle(from: source, for: panes.map(\.id)) }
        catch {
            if !Tako.CustomTabGroup.suppressWindowOrderingForTesting, let window {
                Task { @MainActor in
                    _ = await TerminalDialogView.choose(in: window, title: "Session Not Moved",
                        lines: TUIText.plain("Could not preserve this session's appearance. \(error.localizedDescription)", width: 56),
                        choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: panes.first?.theme)
                }
            }
            return false
        }
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
            .contextMenu {
                Button("Workspace Appearance…") { ScopedAppearanceContext.showWorkspace(group.id) }
            }
            .background(SidebarWorkspaceAXElement(name: group.name, isActive: group.isActive))
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

/// Real AppKit `AXGroup` element exposing `SessionSidebarWorkspace-<name>` with live `"active"` / `"inactive"`
/// `AXValue` while passing all mouse clicks, context menus, and drag-and-drop gestures through untouched.
private final class SidebarWorkspaceAXNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct SidebarWorkspaceAXElement: NSViewRepresentable {
    let name: String
    let isActive: Bool

    func makeNSView(context: Context) -> SidebarWorkspaceAXNSView {
        let view = SidebarWorkspaceAXNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: SidebarWorkspaceAXNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: SidebarWorkspaceAXNSView) {
        view.setAccessibilityIdentifier("SessionSidebarWorkspace-\(name)")
        view.setAccessibilityLabel(name)
        view.setAccessibilityValue(isActive ? "active" : "inactive")
    }
}

struct SidebarWorkspaceMoveModifier: ViewModifier {
    let item: SessionSidebarItem
    let workspaces: [Workspace]
    let onMove: (String, UUID) -> Bool
    let canMoveToWindow: () -> Bool
    let onMoveToWindow: () -> Void
    var onNewSession: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

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
            if let onNewSession {
                Button("New Session", action: onNewSession)
            }
            if !item.isChild, let onRename {
                Button("Rename Session…", action: onRename)
            }
            if let onClose {
                Button(item.isChild ? "Close Pane" : "Close Session", action: onClose)
            }
            if onNewSession != nil || (!item.isChild && onRename != nil) || onClose != nil {
                Divider()
            }
            Button(item.isChild ? "Pane Appearance…" : "Terminal Appearance…") {
                if let id = item.surfaceId { ScopedAppearanceContext.showPane(id) }
            }
            .disabled(item.surfaceId == nil)
            Divider()
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
        .accessibilityElement(children: .contain)
        .accessibilityValue(item.isSelected ? "selected" : "unselected")
        .accessibilityHint(Self.statusDotHint(for: item))
        .accessibilityIdentifier((item.isChild ? "session-pane-" : "session-tab-")
            + (item.surfaceId?.uuidString.lowercased() ?? item.tabId))
    }

    @MainActor
    private static func statusDotHint(for item: SessionSidebarItem) -> String {
        let dot: String
        switch item.status {
        case .working, .running: dot = "ember"
        case .waitingForInput, .needsApproval: dot = "claw"
        case .done: dot = "ok"
        case .error, .disconnected: dot = "error"
        case .idle, .unknown: dot = item.needsAttention ? "claw" : "dim"
        }
        let surface = item.surfaceId.flatMap { id in
            TerminalController.all.flatMap { $0.surfaceTree.map { $0 } }.first { $0.id == id }
        }
        return "dot:\(Tako.tabStatusHex(for: dot, surface: surface))"
    }
}
