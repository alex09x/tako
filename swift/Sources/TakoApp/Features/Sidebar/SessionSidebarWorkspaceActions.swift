/*
 * tako — A workspace's actions in the sidebar (reference A01 `.ws`, wsMenu)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// What a workspace header offers, from its right-click menu, its hover «⋯»
/// and «+», and its colour dot: «New Session Here», «Rename»,
/// «Color ▸», «Minimize»/«Expand», «Appearance ▸» and «Delete Workspace»,
/// which waits until the workspace is empty and is never the last one.
/// Everything goes through `WorkspaceStore`, as the tab bar's picker does.
@MainActor
struct SidebarWorkspaceActions {
    let workspaceID: UUID
    let name: String
    let sessionCount: Int
    let isCollapsed: Bool
    let workspaces: WorkspaceStore
    weak var window: NSWindow?
    var newSession: () -> Void
    var toggleCollapse: () -> Void

    /// The workspace colours Tako draws (`LivingTokens.workspaceColor`); nil is teal.
    static let colors: [(key: String, title: String)] = [
        ("teal", "Teal"), ("purple", "Purple"), ("yellow", "Yellow"),
        ("green", "Green"), ("red", "Red"), ("orange", "Orange"), ("steel", "Blue"),
    ]

    /// The colour as drawn: none, the stored default «blue» and anything
    /// unknown are teal (`LivingTokens.workspaceColor`).
    var color: String { Self.drawnKey(workspaces.workspace(for: workspaceID)?.color) }

    static func drawnKey(_ stored: String?) -> String {
        let key = stored?.lowercased() ?? "teal"
        return colors.contains { $0.key == key } ? key : "teal"
    }

    var canDelete: Bool {
        sessionCount == 0 && workspaces.workspaces.count > 1 && workspaceID != WorkspaceStore.defaultWorkspaceId
    }

    var deleteTitle: String {
        sessionCount > 0 ? "Delete (move \(sessionCount) sessions first)" : "Delete Workspace"
    }

    var collapseTitle: String { isCollapsed ? "Expand" : "Minimize" }

    func setColor(_ key: String) {
        guard var workspace = workspaces.workspace(for: workspaceID) else { return }
        workspace.color = key == "teal" ? nil : key
        workspaces.updateWorkspace(workspace)
    }

    func delete() {
        guard canDelete else { NSSound.beep(); return }
        _ = workspaces.deleteWorkspace(id: workspaceID)
    }

    func rename() {
        guard let window else { return }
        let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme
        Task { @MainActor in
            guard let entered = await TerminalDialogView.askText(
                in: window, title: "Rename Workspace", label: "Name:", value: name,
                hint: "", confirm: "Rename", theme: theme) else { return }
            let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.rename(workspaceID, to: trimmed, in: workspaces)
        }
    }

    /// An empty name keeps the old one.
    static func rename(_ id: UUID, to name: String, in workspaces: WorkspaceStore) {
        guard !name.isEmpty, var workspace = workspaces.workspace(for: id), workspace.name != name else { return }
        workspace.name = name
        workspaces.updateWorkspace(workspace)
    }

    private var appearance: DesktopAppearanceMenu? {
        DesktopAppearanceMenu.make(for: .init(kind: .workspace(workspaceID), kindTitle: "workspace", name: name),
                                   app: (NSApp.delegate as? AppDelegate)?.tako, window: window ?? NSApp.keyWindow)
    }

    // MARK: AppKit («⋯» and the colour dot)

    /// Accessibility identifiers: `SidebarWorkspaceNewSession`, `SidebarWorkspaceRename`,
    /// `SidebarWorkspaceColor-<key>`, `SidebarWorkspaceCollapse`, `SidebarWorkspaceDelete`.
    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(Self.item("New Session Here", id: "SidebarWorkspaceNewSession", run: newSession))
        menu.addItem(Self.item("Rename", id: "SidebarWorkspaceRename", run: rename))
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu()
        menu.addItem(colorItem)
        menu.addItem(Self.item(collapseTitle, id: "SidebarWorkspaceCollapse", run: toggleCollapse))
        if let appearance {
            menu.addItem(.separator())
            menu.addItem(appearance.menuItem())
        }
        menu.addItem(.separator())
        let deleteItem = Self.item(deleteTitle, id: "SidebarWorkspaceDelete", run: delete)
        deleteItem.isEnabled = canDelete
        menu.addItem(deleteItem)
        return menu
    }

    func colorMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in Self.colors {
            let item = Self.item(entry.title, id: "SidebarWorkspaceColor-\(entry.key)") { setColor(entry.key) }
            item.state = color == entry.key ? .on : .off
            item.image = Self.dot(Tako.LivingTokens.workspaceColor(for: entry.key))
            menu.addItem(item)
        }
        return menu
    }

    /// Opens a menu under `anchor`, the control that asked for it.
    static func popUp(_ menu: NSMenu, under anchor: NSView) {
        let below = NSPoint(x: anchor.bounds.minX, y: anchor.isFlipped ? anchor.bounds.maxY + 4 : anchor.bounds.minY - 4)
        menu.popUp(positioning: nil, at: below, in: anchor)
    }

    /// The view with this accessibility identifier in `window`.
    static func anchor(_ identifier: String, in window: NSWindow?) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == identifier { return view }
            for child in view.subviews { if let hit = find(child) { return hit } }
            return nil
        }
        return window?.contentView.flatMap(find)
    }

    private static func item(_ title: String, id: String, run: @escaping () -> Void) -> NSMenuItem {
        let item = SidebarMenuAction(title, binding: "", run: run)
        item.identifier = .init(id)
        return item
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    // MARK: SwiftUI (right click)

    @ViewBuilder
    var contextMenu: some View {
        Button("New Session Here", action: newSession).accessibilityIdentifier("SidebarWorkspaceNewSession")
        Button("Rename", action: rename).accessibilityIdentifier("SidebarWorkspaceRename")
        Menu("Color") {
            ForEach(Self.colors, id: \.key) { entry in
                Toggle(entry.title, isOn: Binding(get: { color == entry.key }, set: { if $0 { setColor(entry.key) } }))
                    .accessibilityIdentifier("SidebarWorkspaceColor-\(entry.key)")
            }
        }
        Button(collapseTitle, action: toggleCollapse).accessibilityIdentifier("SidebarWorkspaceCollapse")
        if let appearance {
            Divider()
            DesktopAppearanceSubmenu(menu: appearance)
        }
        Divider()
        Button(deleteTitle, role: .destructive, action: delete)
            .disabled(!canDelete)
            .accessibilityIdentifier("SidebarWorkspaceDelete")
    }
}
