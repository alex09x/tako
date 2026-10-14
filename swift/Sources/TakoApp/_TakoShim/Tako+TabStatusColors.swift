/*
 * tako — Configurable tab lifecycle colors
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

@MainActor
extension Tako {
    public static var overrideTabStatusTheme: TerminalTheme?

    static var activeTabStatusTheme: TerminalTheme? {
        overrideTabStatusTheme ?? (NSApp?.delegate as? AppDelegate)?.tako.config.theme
    }

    static func tabStatusColor(for dot: String) -> NSColor {
        let keys = ["ember": "working", "claw": "waiting", "ok": "done", "error": "error", "dim": "idle"]
        if let key = keys[dot],
           let theme = activeTabStatusTheme,
           let color = theme.tabStatusColors[key], let nsColor = NSColor(cgColor: color) {
            return nsColor
        }
        return Brand.color(for: dot)
    }

    static func tabStatusHex(for dot: String) -> String {
        Brand.hexString(for: tabStatusColor(for: dot))
    }

    static func tabStatusColorName(for dot: String) -> String {
        let states = ["ember": "working", "claw": "waiting", "ok": "done", "error": "error", "dim": "idle"]
        if let key = states[dot],
           activeTabStatusTheme?.tabStatusColors[key] != nil {
            return tabStatusHex(for: dot)
        }
        return ["ember": "orange", "claw": "amber", "ok": "green", "error": "red", "dim": "gray"][dot] ?? "gray"
    }
}
