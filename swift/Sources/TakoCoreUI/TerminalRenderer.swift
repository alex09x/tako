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

/// Draws a `TakoCore` terminal grid with CoreText.
///
/// The Rust core owns parsing and state, this owns pixels, and nothing in
/// between is a bridge. It draws into any `CGContext`, so the same code backs
/// a `UIView`/`NSView`, a SwiftUI `Canvas`, or an offscreen bitmap.
public struct TerminalRenderer {
    public let metrics: Metrics
    /// Colors used when the terminal says "default" and the host hasn't
    /// overridden them via OSC 10/11.
    public var defaultForeground: CGColor
    public var defaultBackground: CGColor
    /// Selection highlight; drawn under the glyphs so text stays readable.
    public var selectionColor: CGColor
    /// `selection-foreground`: color of selected text. Nil (the default)
    /// keeps each cell's own foreground.
    public var selectionForeground: CGColor?
    /// `selection-invert-fg-bg`: swap each selected cell's own foreground
    /// and background instead of overlaying `selectionColor`/
    /// `selectionForeground`.
    public var selectionInvertFgBg: Bool
    /// The cursor is ember by brand, whatever the palette is.
    public var cursorColor: CGColor
    /// `cursor-opacity`: the cursor's alpha, 0...1.
    public var cursorOpacity: Double
    /// `cursor-thickness`: bar/underline cursor thickness in points. Nil
    /// keeps this renderer's own default (2pt).
    public var cursorThickness: CGFloat?
    /// A pane that does not take the keys draws its cursor as an outline and
    /// dims its text.
    public var unfocused = false

    public init(
        metrics: Metrics,
        defaultForeground: CGColor = srgb(r: 0xed, g: 0xe6, b: 0xdf),
        defaultBackground: CGColor = srgb(r: 0x14, g: 0x10, b: 0x0e),
        selectionColor: CGColor = srgb(0.96, 0.35, 0.11, 0.3),
        selectionForeground: CGColor? = nil,
        selectionInvertFgBg: Bool = false,
        cursorColor: CGColor = srgb(r: 0xf4, g: 0x58, b: 0x1c),
        cursorOpacity: Double = 1.0,
        cursorThickness: CGFloat? = nil
    ) {
        self.metrics = metrics
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.selectionColor = selectionColor
        self.selectionForeground = selectionForeground
        self.selectionInvertFgBg = selectionInvertFgBg
        self.cursorColor = cursorColor
        self.cursorOpacity = cursorOpacity
        self.cursorThickness = cursorThickness
    }

    /// Pixel size of a `cols` x `rows` grid at these metrics.
    public func pixelSize(cols: Int, rows: Int) -> CGSize {
        CGSize(
            width: metrics.cellWidth * CGFloat(cols),
            height: metrics.cellHeight * CGFloat(rows)
        )
    }

    /// Cells arrive as Unicode scalars, and a frame has tens of thousands of
    /// them. ASCII is nearly all of it in practice, so those come from a
    /// table instead of being built again for every cell of every frame.
    private static let ascii: [String] = (0..<128).map {
        String(UnicodeScalar(UInt8($0)))
    }

    public static func string(for scalar: UInt32) -> String {
        if scalar < 128 { return ascii[Int(scalar)] }
        guard let unicode = UnicodeScalar(scalar) else { return " " }
        return String(unicode)
    }
}
