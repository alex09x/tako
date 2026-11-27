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
import TakoCoreUI

extension Notification.Name {
    /// A terminal's temporary zoom changed (object: the SurfaceView).
    static let takoSurfaceZoomDidChange = Notification.Name("takoSurfaceZoomDidChange")
}

extension Tako.SurfaceView {
    /// The terminal's menu (link, path, command or default), this terminal's
    /// zoom after «Select All» (reference prefs-detail.js: «Zoom In»,
    /// «Zoom Out», «Reset Zoom») and its «Appearance ▸» at the pane level.
    override open func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let zoom = zoomMenuItems()
        if let selectAll = menu.items.firstIndex(where: { $0.action == #selector(selectAll(_:)) }) {
            for (offset, item) in ([NSMenuItem.separator()] + zoom).enumerated() {
                menu.insertItem(item, at: selectAll + 1 + offset)
            }
        } else {
            menu.addItem(.separator())
            zoom.forEach(menu.addItem)
        }
        if let item = appearanceMenuItem() {
            menu.addItem(.separator())
            menu.addItem(item)
        }
        return menu
    }

    /// Accessibility identifiers: `TerminalZoomIn`, `TerminalZoomOut`, `TerminalZoomReset`.
    func zoomMenuItems() -> [NSMenuItem] {
        let bigger = SidebarMenuAction("Zoom In", binding: "increase_font_size:1") { [weak self] in
            self?.changeFontSize(.increase(1))
        }
        bigger.identifier = .init("TerminalZoomIn")
        let smaller = SidebarMenuAction("Zoom Out", binding: "decrease_font_size:1") { [weak self] in
            self?.changeFontSize(.decrease(1))
        }
        smaller.identifier = .init("TerminalZoomOut")
        let reset = SidebarMenuAction("Reset Zoom", binding: "reset_font_size") { [weak self] in
            self?.changeFontSize(.reset)
        }
        reset.identifier = .init("TerminalZoomReset")
        reset.isEnabled = fontZoomDelta != 0
        return [bigger, smaller, reset]
    }

    /// Nil when the terminal is not in a live window (nothing to edit).
    func appearanceMenuItem() -> NSMenuItem? {
        let level = DesktopScopeLevel(kind: .pane(id), kindTitle: "terminal", name: title.isEmpty ? "terminal" : title)
        return DesktopAppearanceMenu.make(for: level, app: app ?? (NSApp.delegate as? AppDelegate)?.tako,
                                          window: window)?.menuItem()
    }
}
