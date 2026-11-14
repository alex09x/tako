/*
 * tako — Moving a pane into another tab (pane-header menu «Move to Tab»)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// «Move to Tab ▸»: every other tab of the pane's workspace, in any window.
/// Choosing one moves the pane in beside that tab's focused pane, on its
/// right, and brings that tab to the front.
/// Accessibility identifiers: `PaneMenuMoveToTab`, `PaneMenuMoveToTab-<n>`.
@MainActor
enum MovePaneToTab {
    /// The tabs `surface` can join: same workspace, not its own, not empty.
    static func destinations(for surface: Tako.SurfaceView) -> [BaseTerminalController] {
        let own = BaseTerminalController.owningController(for: surface)
        let workspace = own?.window.flatMap { WorkspaceStore.shared.workspace(forTab: $0.stableTabIdentifier)?.id }
        return TerminalController.all.filter { controller in
            guard controller !== own, !controller.surfaceTree.isEmpty, let window = controller.window else { return false }
            return WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier)?.id == workspace
        }
    }

    /// The pane the newcomer goes beside: the tab's focused one, else its first.
    static func anchor(in controller: BaseTerminalController) -> Tako.SurfaceView? {
        if let focused = controller.focusedSurface, controller.surfaceTree.contains(focused) { return focused }
        return controller.surfaceTree.first
    }

    /// Moves `surface` into `controller`'s tab.
    static func move(
        _ surface: Tako.SurfaceView, into controller: BaseTerminalController,
        beside anchor: Tako.SurfaceView? = nil,
        direction: SplitTree<Tako.SurfaceView>.NewDirection = .right, select: Bool = true
    ) throws {
        guard let anchor = anchor ?? Self.anchor(in: controller) else {
            throw MovePaneError(description: "the tab has no pane to move beside")
        }
        try controller.movePaneHere(surface, beside: anchor, direction: direction, select: select)
    }

    static func title(of controller: BaseTerminalController) -> String {
        let title = controller.window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Terminal" : title
    }

    /// The tab `surface` can leave for a new tab of its own: one it shares with other panes.
    static func splitTab(of surface: Tako.SurfaceView) -> TerminalController? {
        guard let own = BaseTerminalController.owningController(for: surface) as? TerminalController,
              own.surfaceTree.isSplit else { return nil }
        return own
    }

    /// The submenu item: every other tab of the workspace, then «New Tab»
    /// while the pane shares its tab. Disabled when neither applies.
    /// Accessibility identifier of «New Tab»: `PaneMenuMoveToNewTab`.
    static func menuItem(for surface: Tako.SurfaceView) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to Tab", action: nil, keyEquivalent: "")
        item.identifier = .init("PaneMenuMoveToTab")
        let entries = entries(for: surface)
        item.isEnabled = !entries.isEmpty
        guard item.isEnabled else { return item }
        item.submenu = menu(of: entries)
        return item
    }

    /// The header button's menu, a menu of its own (never another item's
    /// submenu): the same choices, or a disabled line saying there is nowhere to go.
    static func buttonMenu(for surface: Tako.SurfaceView) -> NSMenu {
        let entries = entries(for: surface)
        guard entries.isEmpty else { return menu(of: entries) }
        let none = NSMenuItem(title: "No Other Tab in This Workspace", action: nil, keyEquivalent: "")
        none.isEnabled = false
        return menu(of: [none])
    }

    private static func menu(of items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: "Move to Tab")
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    /// Every other tab of the workspace, then «New Tab» while the pane shares its tab.
    private static func entries(for surface: Tako.SurfaceView) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (index, controller) in destinations(for: surface).enumerated() {
            let entry = SidebarMenuAction(title(of: controller), binding: "") { [weak surface, weak controller] in
                guard let surface, let controller else { return }
                attempt(for: surface) { try move(surface, into: controller) }
            }
            entry.identifier = .init("PaneMenuMoveToTab-\(index)")
            items.append(entry)
        }
        if splitTab(of: surface) != nil {
            if !items.isEmpty { items.append(.separator()) }
            let entry = SidebarMenuAction("New Tab", binding: "") { [weak surface] in
                guard let surface else { return }
                attempt(for: surface) {
                    guard let tab = splitTab(of: surface) else {
                        throw MovePaneError(description: "the pane no longer shares its tab")
                    }
                    try tab.movePaneToNewTab(surface)
                }
            }
            entry.identifier = .init("PaneMenuMoveToNewTab")
            items.append(entry)
        }
        return items
    }

    /// Runs a move; a refusal is logged and said in the pane's window.
    static func attempt(for surface: Tako.SurfaceView, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Tako.logger.warning("move to tab failed: \(String(describing: error), privacy: .public)")
            report(error, for: surface)
        }
    }

    /// A refused move says why in the pane's window, as a refused session move does.
    private static func report(_ error: Error, for surface: Tako.SurfaceView) {
        guard !Tako.CustomTabGroup.suppressWindowOrderingForTesting,
              let window = surface.window ?? BaseTerminalController.owningController(for: surface)?.window else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            _ = await TerminalDialogView.choose(in: window, title: "Pane Not Moved",
                lines: TUIText.plain(String(describing: error), width: 56),
                choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: surface.theme)
        }
    }
}
