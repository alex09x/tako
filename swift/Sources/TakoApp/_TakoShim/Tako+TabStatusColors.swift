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

    public static func effectiveTabStatusTheme(
        theme: TerminalTheme? = nil,
        surface: Tako.SurfaceView? = nil,
        window: NSWindow? = nil
    ) -> TerminalTheme? {
        if let override = overrideTabStatusTheme {
            return override
        }
        if let theme {
            return theme
        }
        if let surface {
            return surface.theme
        }
        if let window {
            if let contributing = contributingSurface(for: window) {
                return contributing.theme
            }
            if let base = window.windowController as? TerminalController, let focused = base.focusedSurface {
                return focused.theme
            }
        }
        return (NSApp?.delegate as? AppDelegate)?.tako.config.theme
    }

    static var activeTabStatusTheme: TerminalTheme? {
        effectiveTabStatusTheme()
    }

    public static func tabStatusPalette(
        theme: TerminalTheme? = nil,
        surface: Tako.SurfaceView? = nil,
        window: NSWindow? = nil
    ) -> TabStatusPalette {
        let resolvedTheme = effectiveTabStatusTheme(theme: theme, surface: surface, window: window)
        return TabStatusPalette(theme: resolvedTheme)
    }

    public static func tabStatusColor(
        for dot: String,
        theme: TerminalTheme? = nil,
        surface: Tako.SurfaceView? = nil,
        window: NSWindow? = nil
    ) -> NSColor {
        tabStatusPalette(theme: theme, surface: surface, window: window).color(for: dot)
    }

    public static func tabStatusHex(
        for dot: String,
        theme: TerminalTheme? = nil,
        surface: Tako.SurfaceView? = nil,
        window: NSWindow? = nil
    ) -> String {
        tabStatusPalette(theme: theme, surface: surface, window: window).hex(for: dot)
    }

    public static func tabStatusColorName(
        for dot: String,
        theme: TerminalTheme? = nil,
        surface: Tako.SurfaceView? = nil,
        window: NSWindow? = nil
    ) -> String {
        tabStatusPalette(theme: theme, surface: surface, window: window).colorName(for: dot)
    }
}
