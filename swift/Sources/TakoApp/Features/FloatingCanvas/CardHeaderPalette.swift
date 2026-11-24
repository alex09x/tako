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

    /// The title is at least this readable on the fill (WCAG AA for text)...
    static let titleContrast: CGFloat = 4.5
    /// ...and the quieter secondary text at least this.
    static let secondaryContrast: CGFloat = 3

    init(background: CGColor, foreground: CGColor) {
        let bg = NSColor(cgColor: background)?.usingColorSpace(.sRGB) ?? .black
        let fg = NSColor(cgColor: foreground)?.usingColorSpace(.sRGB) ?? .white
        fill = bg
        // The terminal's foreground where it is readable enough; otherwise
        // whichever of black and white stands out more on this background
        // (a mid-grey's better one is not always the one its luminance suggests).
        let title = Self.contrast(of: fg, on: bg) >= Self.titleContrast ? fg
            : [NSColor.black, .white].max { Self.contrast(of: $0, on: bg) < Self.contrast(of: $1, on: bg) }!
        self.title = title
        // Quiet where the background allows it, never below the secondary bound.
        let alpha = stride(from: 0.66, through: 1.0, by: 0.02).first {
            Self.contrast(of: title.withAlphaComponent($0), on: bg) >= Self.secondaryContrast
        } ?? 1
        secondary = title.withAlphaComponent(alpha)
        faint = title.withAlphaComponent(alpha * 0.45 / 0.66)
        hover = title.withAlphaComponent(0.10)
        isLight = CanvasPaneTitleColor.luminance(bg) > 0.5
    }

    @MainActor static func of(_ surface: Tako.SurfaceView) -> CardHeaderPalette {
        CardHeaderPalette(background: surface.drawnBackground, foreground: surface.drawnForeground)
    }

    /// WCAG contrast of `color` (composited over `fill` when translucent) against `fill`.
    func contrast(of color: NSColor) -> CGFloat { Self.contrast(of: color, on: fill) }

    static func contrast(of color: NSColor, on fill: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color, a = c.alphaComponent
        let mixed = NSColor(srgbRed: c.redComponent * a + fill.redComponent * (1 - a),
                            green: c.greenComponent * a + fill.greenComponent * (1 - a),
                            blue: c.blueComponent * a + fill.blueComponent * (1 - a), alpha: 1)
        let (l1, l2) = (CanvasPaneTitleColor.luminance(mixed), CanvasPaneTitleColor.luminance(fill))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
