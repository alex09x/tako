/*
 * tako — «Appearance ▸» on a terminal's own right-click menu
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension Tako.SurfaceView {
    /// The terminal's menu (link, path, command or default) plus this
    /// terminal's «Appearance ▸» at the pane level.
    override open func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        if let item = appearanceMenuItem() {
            menu.addItem(.separator())
            menu.addItem(item)
        }
        return menu
    }

    /// Nil when the terminal is not in a live window (nothing to edit).
    func appearanceMenuItem() -> NSMenuItem? {
        let level = DesktopScopeLevel(kind: .pane(id), kindTitle: "terminal", name: title.isEmpty ? "terminal" : title)
        return DesktopAppearanceMenu.make(for: level, app: app ?? (NSApp.delegate as? AppDelegate)?.tako,
                                          window: window)?.menuItem()
    }
}
