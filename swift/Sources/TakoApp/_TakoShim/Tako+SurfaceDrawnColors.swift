/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics

extension Tako.SurfaceView {
    /// The background and foreground the engine draws default cells in. They
    /// are the theme's until a program sets its own (OSC 10/11), and a
    /// restored session can carry such a colour in; a later theme leaves it
    /// be. So the theme alone does not say what the screen shows: a card
    /// filled with the theme's background stood out as a frame round a
    /// terminal still drawn in the restored session's.
    struct DrawnColors: Equatable {
        var background: FfiRgb?
        var foreground: FfiRgb?
    }

    /// Reads the engine's colours again (two FFI reads, each taking the
    /// engine's lock) and publishes only a change.
    func refreshDrawnColors() {
        let now = DrawnColors(background: core.defaultBackground(), foreground: core.defaultForeground())
        if now != drawnColors { drawnColors = now }
    }

    /// The background default cells are drawn in (the theme's while the
    /// engine has none).
    var drawnBackground: CGColor { drawnColors.background.map(Self.cgColor) ?? theme.background }

    /// The foreground default cells are drawn in (the theme's while the
    /// engine has none).
    var drawnForeground: CGColor { drawnColors.foreground.map(Self.cgColor) ?? theme.foreground }

    /// Hands the theme's `bold-is-bright` to the engine, which resolves the
    /// colours it draws. Here rather than in `TakoCore.setBaseColors(from:)`
    /// until the engine release that ships `set_bold_is_bright`: see
    /// `TerminalTheme.boldIsBright`.
    func applyBoldIsBright(_ theme: TerminalTheme) {
        core.setBoldIsBright(enabled: theme.boldIsBright)
    }

    private static func cgColor(_ rgb: FfiRgb) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}
