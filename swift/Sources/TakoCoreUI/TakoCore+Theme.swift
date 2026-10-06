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
import Foundation

extension TakoCore {
    /// Makes `theme`'s colors the engine's base colors: what a program's
    /// OSC 104/110/111/112 and a reset return to, and what color queries
    /// report until a program sets its own. Colors a program has already set
    /// stay as it set them, so this is safe to call on every theme change.
    ///
    /// Feeding the theme as OSC 4/10/11/12 instead would make it a program
    /// override: a program resetting "its" colors on exit would then land on
    /// the engine's built-ins rather than the theme.
    public func setBaseColors(from theme: TerminalTheme) {
        let palette: [FfiPaletteEntry] = theme.palette
            .sorted(by: { $0.key < $1.key })
            .compactMap { index, color in
                guard (0..<256).contains(index), let value = Self.rgb(color) else { return nil }
                return FfiPaletteEntry(index: UInt8(index), color: value)
            }
        setBaseColors(
            foreground: Self.rgb(theme.foreground),
            background: Self.rgb(theme.background),
            cursor: Self.rgb(theme.cursorColor),
            palette: palette)
    }

    /// Makes `theme`'s cursor the engine's default: what a program's
    /// DECSCUSR 0 and a reset return to. A style the program chose stays.
    public func setDefaultCursorStyle(from theme: TerminalTheme) {
        setDefaultCursorStyle(shape: theme.cursorShape, blinking: theme.cursorBlink)
    }

    /// Makes `theme`'s `grapheme-width-method` the engine's: mode 2027's
    /// value now and after a reset.
    public func setGraphemeWidthMethod(from theme: TerminalTheme) {
        setGraphemeWidthMethod(method: theme.graphemeWidthMethod)
    }

    /// Tells the engine whether `theme` is dark, judged by its background:
    /// what a program asking `CSI ? 996 n` is drawing on, whatever the
    /// system's appearance.
    public func setColorScheme(from theme: TerminalTheme) {
        setColorScheme(dark: Self.isDark(theme.background))
    }

    /// Whether `color` reads as a dark background: perceived brightness
    /// (Rec. 601 weights) below half. A colour with no RGB form counts as
    /// dark, as the default theme is.
    static func isDark(_ color: CGColor) -> Bool {
        guard let rgb = rgb(color) else { return true }
        let brightness = 0.299 * Double(rgb.r) + 0.587 * Double(rgb.g) + 0.114 * Double(rgb.b)
        return brightness < 127.5
    }

    /// `color` as sRGB bytes, rounded; nil when it has no RGB form.
    static func rgb(_ color: CGColor) -> FfiRgb? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let srgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let c = srgb.components, c.count >= 3 else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        return FfiRgb(r: byte(c[0]), g: byte(c[1]), b: byte(c[2]))
    }
}
