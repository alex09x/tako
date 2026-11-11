/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// A terminal card's header colours, taken from the terminal it heads: the
/// card is one surface in the terminal's own background, header included, so
/// its title and controls must be readable on that background whatever the
/// shell's scheme. A light terminal in a dark shell, or the reverse, keeps a
/// readable header. Status and accent colours (the ring, close, pressed) stay
/// the shell's: they are the same in every scheme.
struct CardHeaderPalette: Equatable {
    /// The card's fill: header and margin alike, the terminal's background.
    let fill: NSColor
    /// The focused title, readable on `fill` (the terminal's foreground, or
    /// black/white where that foreground is too close to the background).
    let title: NSColor
    /// The unfocused title, the directory and quiet controls.
    let secondary: NSColor
    /// An unfocused pane's directory and resting controls.
    let faint: NSColor
    /// A hovered control's backing.
    let hover: NSColor
    /// Whether the fill is light (for the header's own system drawing).
    let isLight: Bool

    init(background: CGColor, foreground: CGColor) {
        let bg = NSColor(cgColor: background)?.usingColorSpace(.sRGB) ?? .black
        let fg = NSColor(cgColor: foreground)?.usingColorSpace(.sRGB) ?? .white
        let title = CanvasPaneTitleColor.color(foreground: fg, background: bg)
        fill = bg
        self.title = title
        secondary = title.withAlphaComponent(0.66)
        faint = title.withAlphaComponent(0.45)
        hover = title.withAlphaComponent(0.10)
        isLight = CanvasPaneTitleColor.luminance(bg) > 0.5
    }

    @MainActor static func of(_ surface: Tako.SurfaceView) -> CardHeaderPalette {
        CardHeaderPalette(background: surface.theme.background, foreground: surface.theme.foreground)
    }

    /// WCAG contrast of `color` (composited over `fill` when translucent) against `fill`.
    func contrast(of color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color, a = c.alphaComponent
        let mixed = NSColor(srgbRed: c.redComponent * a + fill.redComponent * (1 - a),
                            green: c.greenComponent * a + fill.greenComponent * (1 - a),
                            blue: c.blueComponent * a + fill.blueComponent * (1 - a), alpha: 1)
        let (l1, l2) = (CanvasPaneTitleColor.luminance(mixed), CanvasPaneTitleColor.luminance(fill))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
