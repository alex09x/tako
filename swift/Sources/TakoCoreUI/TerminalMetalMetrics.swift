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
import CoreText
import Foundation
import simd

/// The colors the renderer falls back to when the terminal says "default",
/// plus the two overlays the palette never supplies. Straight (not
/// premultiplied) components, in the renderer's `colorEncoding`.
public struct TerminalMetalPalette: Equatable, Sendable {
    public var background: SIMD4<Float>
    public var foreground: SIMD4<Float>
    public var selection: SIMD4<Float>
    /// `selection-foreground`: the colour of selected text; nil keeps each
    /// cell's own.
    public var selectionForeground: SIMD4<Float>?
    /// `selection-invert-fg-bg`: a selected cell swaps its own foreground and
    /// background, and no selection colour is laid over it.
    public var selectionInvertsColors: Bool
    public var cursor: SIMD4<Float>
    /// Alpha applied to text in a pane that does not take the keys.
    public var unfocusedTextAlpha: Float
    /// Alpha applied to text drawn with SGR 2 (dim).
    public var dimAlpha: Float

    public init(
        background: SIMD4<Float>,
        foreground: SIMD4<Float>,
        selection: SIMD4<Float>,
        cursor: SIMD4<Float>,
        unfocusedTextAlpha: Float = 0.75,
        dimAlpha: Float = 0.6,
        selectionForeground: SIMD4<Float>? = nil,
        selectionInvertsColors: Bool = false
    ) {
        self.background = background
        self.foreground = foreground
        self.selection = selection
        self.selectionForeground = selectionForeground
        self.selectionInvertsColors = selectionInvertsColors
        self.cursor = cursor
        self.unfocusedTextAlpha = unfocusedTextAlpha
        self.dimAlpha = dimAlpha
    }

    /// The same defaults `TerminalRenderer` draws with: Prod's own palette,
    /// with the ember cursor the brand owns.
    public static func standard(
        encoding: TerminalMetalColorEncoding = .displayEncoded,
        colorSpace: TerminalMetalColorSpace = .sRGB
    ) -> TerminalMetalPalette {
        TerminalMetalPalette(
            background: TerminalMetalColor.rgba(r: 0x14, g: 0x10, b: 0x0e, encoding: encoding, colorSpace: colorSpace),
            foreground: TerminalMetalColor.rgba(r: 0xed, g: 0xe6, b: 0xdf, encoding: encoding, colorSpace: colorSpace),
            selection: TerminalMetalColor.rgba(r: 0xf5, g: 0x59, b: 0x1c, alpha: 0.3, encoding: encoding, colorSpace: colorSpace),
            cursor: TerminalMetalColor.rgba(r: 0xf4, g: 0x58, b: 0x1c, encoding: encoding, colorSpace: colorSpace)
        )
    }
}

/// The space around the grid, in drawable pixels, and what fills it
/// (`window-padding-color`).
public struct TerminalMetalMargins: Equatable, Sendable {
    public enum Fill: Equatable, Sendable {
        /// The frame's clear colour: the default background.
        case background
        /// The nearest cell's background. Above and below the grid only when
        /// that edge row has no default-background cell, or on the alternate
        /// screen, so a prompt's colours do not bleed into the margin.
        case extend
        /// The nearest cell's background, always.
        case extendAlways
    }

    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float
    public var fill: Fill

    public init(left: Float = 0, top: Float = 0, right: Float = 0, bottom: Float = 0, fill: Fill = .background) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.fill = fill
    }
}

/// Cell geometry in points plus the scale that turns it into drawable pixels.
public struct TerminalMetalCellMetrics {
    public let font: CTFont
    /// Face used for cells with SGR 1 set, when the host has one.
    public let boldFont: CTFont?
    public let italicFont: CTFont?
    public let boldItalicFont: CTFont?
    /// Bold and bold-italic faces thickened at raster time.
    public let boldIsSynthetic: Bool
    public let boldItalicIsSynthetic: Bool
    /// Glyphs are shaped, so `font-feature` substitutions apply.
    public let shapesGlyphs: Bool
    /// Cell size in points.
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    /// Points from the top of a cell down to the text baseline.
    public let ascent: CGFloat
    /// Points from the top of a cell down to the top of the underline.
    public let underlinePosition: CGFloat
    public let underlineThickness: CGFloat
    /// Drawable pixels per point. `CAMetalLayer.contentsScale` on a Retina
    /// display, 1 for an offscreen pixel-space target.
    public let scale: CGFloat

    public var pixelCellWidth: Float { Float(cellWidth * scale) }
    public var pixelCellHeight: Float { Float(cellHeight * scale) }
    public var pixelAscent: Float { Float(ascent * scale) }

    public init(
        font: CTFont,
        boldFont: CTFont? = nil,
        italicFont: CTFont? = nil,
        boldItalicFont: CTFont? = nil,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        ascent: CGFloat,
        scale: CGFloat = 1,
        boldIsSynthetic: Bool = false,
        boldItalicIsSynthetic: Bool = false,
        shapesGlyphs: Bool = false,
        underlinePosition: CGFloat? = nil,
        underlineThickness: CGFloat = 1
    ) {
        self.font = font
        self.boldFont = boldFont
        self.italicFont = italicFont
        self.boldItalicFont = boldItalicFont
        self.boldIsSynthetic = boldIsSynthetic
        self.boldItalicIsSynthetic = boldItalicIsSynthetic
        self.shapesGlyphs = shapesGlyphs
        self.cellWidth = max(cellWidth, 1)
        self.cellHeight = max(cellHeight, 1)
        self.ascent = ascent
        self.underlinePosition = underlinePosition ?? ascent + 1
        self.underlineThickness = underlineThickness
        self.scale = max(scale, 0.001)
    }

    /// Reuse the CoreText metrics `TerminalRenderer` already derives, so the
    /// two renderers put the same grid in the same place.
    public init(_ metrics: TerminalRenderer.Metrics, scale: CGFloat = 1) {
        self.init(
            font: metrics.font,
            boldFont: metrics.boldFont,
            italicFont: metrics.italicFont,
            boldItalicFont: metrics.boldItalicFont,
            cellWidth: metrics.cellWidth,
            cellHeight: metrics.cellHeight,
            ascent: metrics.cellHeight - metrics.baseline,
            scale: scale,
            boldIsSynthetic: metrics.boldIsSynthetic,
            boldItalicIsSynthetic: metrics.boldItalicIsSynthetic,
            shapesGlyphs: metrics.hasFontFeatures,
            underlinePosition: metrics.underlinePosition,
            underlineThickness: metrics.underlineThickness
        )
    }

    public init(fontSize: CGFloat, fontName: String? = nil, scale: CGFloat = 1) {
        self.init(TerminalRenderer.Metrics(fontSize: fontSize, fontName: fontName), scale: scale)
    }

    /// Pixel size of a `cols` x `rows` grid at these metrics.
    public func pixelSize(cols: Int, rows: Int) -> SIMD2<Float> {
        SIMD2<Float>(pixelCellWidth * Float(max(cols, 0)), pixelCellHeight * Float(max(rows, 0)))
    }
}
