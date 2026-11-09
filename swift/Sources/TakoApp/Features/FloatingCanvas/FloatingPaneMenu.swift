/*
 * tako — A pane header's own menu (reference header.js winMenu)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// The pane's own actions at the top of its header's right-click menu:
/// «Split Right», «Split Down» (in the grid only, as in the
/// reference), «Expand»/«Restore», «Float Terminal»/«Return to
/// grid», «Minimize» and «Close Terminal». Each runs the same action as
/// the header's buttons or the split shortcuts.
/// Accessibility identifiers: `FloatingPaneMenuSplitRight`, `…SplitDown`,
/// `…Maximize`, `…Float`, `…Minimize`, `…Close`.
@MainActor
struct FloatingPaneMenu {
    let mode: FloatingPaneMode
    let isTiled: Bool
    var split: (SplitTree<Tako.SurfaceView>.NewDirection) -> Void
    var toggleMaximize: () -> Void
    var toggleFloating: () -> Void
    var minimize: () -> Void
    var close: () -> Void

    /// Free floating: not in a grid cell, so nothing to split beside.
    private var isFree: Bool { !isTiled }

    var maximizeTitle: String { mode == .maximized ? "Restore" : "Expand" }
    var floatTitle: String { isFree ? "Return to Grid" : "Float Terminal" }

    func items() -> [NSMenuItem] {
        let right = Self.item("Split Right", binding: "new_split:right", id: "FloatingPaneMenuSplitRight") { split(.right) }
        let down = Self.item("Split Down", binding: "new_split:down", id: "FloatingPaneMenuSplitDown") { split(.down) }
        right.isEnabled = !isFree
        down.isEnabled = !isFree
        return [
            right, down, .separator(),
            Self.item(maximizeTitle, binding: "", id: "FloatingPaneMenuMaximize", run: toggleMaximize),
            Self.item(floatTitle, binding: "", id: "FloatingPaneMenuFloat", run: toggleFloating),
            Self.item("Minimize", binding: "", id: "FloatingPaneMenuMinimize", run: minimize),
            .separator(),
            Self.item("Close Terminal", binding: "close_surface", id: "FloatingPaneMenuClose", run: close),
        ]
    }

    private static func item(_ title: String, binding: String, id: String, run: @escaping () -> Void) -> NSMenuItem {
        let item = SidebarMenuAction(title, binding: binding, run: run)
        item.identifier = .init(id)
        return item
    }
}
