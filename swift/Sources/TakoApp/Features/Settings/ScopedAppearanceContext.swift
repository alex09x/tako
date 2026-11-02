/*
 * tako — Scoped appearance editor
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// The settings dialog edits one explicit scope; inherited values are read
/// afresh so moving a pane while the dialog is open cannot freeze its parent.
@MainActor final class ScopedAppearanceContext {
    static let keys: Set<String> = ["theme", "font-family", "font-size", "background",
                                    "foreground", "cursor-color", "selection-background"]
    let scope: AppearanceScope
    let title: String
    let store: ScopedAppearanceStore
    let globalTheme: () -> TerminalTheme
    let workspaceID: () -> UUID?
    let isAvailable: () -> Bool
    private(set) var writeError: String?

    init(scope: AppearanceScope, title: String, store: ScopedAppearanceStore = .shared,
         globalTheme: @escaping () -> TerminalTheme, workspaceID: @escaping () -> UUID? = { nil },
         isAvailable: @escaping () -> Bool = { true }) {
        self.scope = scope
        self.title = title
        self.store = store
        self.globalTheme = globalTheme
        self.workspaceID = workspaceID
        self.isAvailable = isAvailable
    }

    var effectiveTheme: TerminalTheme {
        switch scope {
        case .workspace(let id): return store.effectiveTheme(global: globalTheme(), workspaceID: id, paneID: nil)
        case .pane(let id): return store.effectiveTheme(global: globalTheme(), workspaceID: workspaceID(), paneID: id)
        }
    }

    func value(for key: String) -> String? { store.value(for: key, scope: scope) }

    func previewInheriting(_ key: String) -> TerminalTheme {
        switch scope {
        case .workspace(let id): return store.previewRemoving(key, scope: scope, global: globalTheme(), workspaceID: id, paneID: nil)
        case .pane(let id): return store.previewRemoving(key, scope: scope, global: globalTheme(), workspaceID: workspaceID(), paneID: id)
        }
    }

    @discardableResult func setValue(_ value: String?, for key: String) -> Bool {
        guard isAvailable() else { writeError = "This workspace or pane has been closed."; return false }
        do {
            try store.setValue(value, for: key, scope: scope)
            writeError = nil
            return true
        } catch {
            writeError = error.localizedDescription
            return false
        }
    }

    func effectiveValue(for key: String) -> String? {
        let theme = effectiveTheme
        switch key {
        case "font-family": return theme.fontFamily ?? TerminalAppearanceCatalog.defaultFont
        case "font-size": return theme.fontSize.rounded() == theme.fontSize ? String(Int(theme.fontSize)) : String(Double(theme.fontSize))
        case "background": return Self.hex(theme.background)
        case "foreground": return Self.hex(theme.foreground)
        case "cursor-color": return Self.hex(theme.cursorColor)
        case "selection-background": return Self.hex(theme.selectionBackground)
        default: return value(for: key)
        }
    }

    private static func hex(_ color: CGColor) -> String? {
        guard let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

extension ScopedAppearanceContext {
    private static var terminalKeyWindow: NSWindow? {
        guard let window = NSApp.keyWindow, window.windowController is TerminalController else { return nil }
        return window
    }

    static func showWorkspace(_ id: UUID, in window: NSWindow? = nil) {
        let workspaces = WorkspaceStore.shared
        guard let workspace = workspaces.workspace(for: id),
              let host = window ?? terminalKeyWindow ?? TerminalController.preferredParent?.window,
              let app = (host.windowController as? TerminalController)?.tako else { return }
        let context = ScopedAppearanceContext(scope: .workspace(id), title: "Workspace: \(workspace.name)",
            globalTheme: { [weak app] in app?.config.theme ?? .takoDefault },
            isAvailable: { workspaces.workspace(for: id) != nil })
        TerminalSettingsDialog.show(in: host, theme: context.effectiveTheme, tab: .themes, appearance: context)
    }

    static func showPane(_ id: UUID, in window: NSWindow? = nil) {
        guard let controller = TerminalController.all.first(where: { $0.surfaceTree.contains { $0.id == id } }),
              let surface = controller.surfaceTree.first(where: { $0.id == id }),
              let host = controller.window else { return }
        // The row may belong to another hidden tab. Show its editor in the
        // current window without selecting or recreating any terminal.
        let context = ScopedAppearanceContext(scope: .pane(id), title: "Pane appearance",
            globalTheme: { [weak surface] in surface?.app?.config.theme ?? .takoDefault },
            workspaceID: { [weak surface] in surface?.appearanceWorkspaceID },
            isAvailable: { [weak surface] in surface != nil && TerminalController.all.contains { $0.surfaceTree.contains { $0.id == id } } })
        TerminalSettingsDialog.show(in: window ?? terminalKeyWindow ?? host, theme: context.effectiveTheme, tab: .themes, appearance: context)
    }
}
