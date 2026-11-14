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
        try controller.movePaneHere(surface, beside: anchor, direction: direction)
        if select { controller.bringTabToFront() }
    }

    static func title(of controller: BaseTerminalController) -> String {
        let title = controller.window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Terminal" : title
    }

    /// The submenu item; disabled when there is no other tab to join.
    static func menuItem(for surface: Tako.SurfaceView) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to Tab", action: nil, keyEquivalent: "")
        item.identifier = .init("PaneMenuMoveToTab")
        let destinations = destinations(for: surface)
        item.isEnabled = !destinations.isEmpty
        guard !destinations.isEmpty else { return item }
        let submenu = NSMenu(title: "Move to Tab")
        submenu.autoenablesItems = false
        for (index, controller) in destinations.enumerated() {
            let entry = SidebarMenuAction(title(of: controller), binding: "") { [weak surface, weak controller] in
                guard let surface, let controller else { return }
                do {
                    try move(surface, into: controller)
                } catch {
                    Tako.logger.warning("move to tab failed: \(String(describing: error), privacy: .public)")
                    NSSound.beep()
                }
            }
            entry.identifier = .init("PaneMenuMoveToTab-\(index)")
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }
}
