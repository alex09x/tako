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

/// CPU and Metal representation of one atlas page.
@frozen public enum GlyphAtlasPixelFormat: UInt32, Sendable, Equatable {
    case grayscale8 = 0
    case bgra8Premultiplied = 1

    public var bytesPerPixel: Int { self == .grayscale8 ? 1 : 4 }
}

/// Key uniquely identifying a rasterized glyph variant in the atlas.
public struct GlyphAtlasKey: Hashable, Equatable, Sendable {
    public let glyph: CGGlyph
    public let fontName: String
    public let fontSize: CGFloat
    public let scale: CGFloat
    public let pixelFormat: GlyphAtlasPixelFormat
    /// Horizontal slant from the font matrix: a synthesised italic shares
    /// its PostScript name with the upright face.
    public let skew: CGFloat
    /// Drawn thickened, as a synthesised bold.
    public let emboldened: Bool
    /// A shaped grapheme cluster rather than one glyph: `glyph` is 0 and
    /// `fontName` is the face the cluster was shaped with.
    public let cluster: String?

    public init(
        glyph: CGGlyph,
        fontName: String,
        fontSize: CGFloat,
        scale: CGFloat = 1.0,
        pixelFormat: GlyphAtlasPixelFormat = .grayscale8,
        skew: CGFloat = 0,
        emboldened: Bool = false,
        cluster: String? = nil
    ) {
        self.glyph = glyph
        self.fontName = fontName
        self.fontSize = fontSize
        self.scale = scale
        self.pixelFormat = pixelFormat
        self.skew = skew
        self.emboldened = emboldened
        self.cluster = cluster
    }

    public init(
        glyph: CGGlyph,
        font: CTFont,
        scale: CGFloat = 1.0,
        pixelFormat: GlyphAtlasPixelFormat? = nil,
        emboldened: Bool = false
    ) {
        let name = CTFontCopyPostScriptName(font) as String
        let size = CTFontGetSize(font)
        let resolvedFormat = pixelFormat ?? (Self.isColorFont(font) ? .bgra8Premultiplied : .grayscale8)
        self.init(
            glyph: glyph,
            fontName: name,
            fontSize: size,
            scale: scale,
            pixelFormat: resolvedFormat,
            skew: CTFontGetMatrix(font).c,
            emboldened: emboldened
        )
    }

    /// Whether `font` draws colour glyphs (an emoji face).
    static func isColorFont(_ font: CTFont) -> Bool {
        CTFontGetSymbolicTraits(font).contains(CTFontSymbolicTraits(rawValue: 1 << 13))
    }
}

/// Metadata and atlas coordinates for a rasterized glyph, suitable for Metal text rendering.
public struct GlyphAtlasEntry: Sendable, Equatable {
    public let key: GlyphAtlasKey
    /// The index of the atlas page containing this glyph's mask.
    public let pageIndex: Int
    public let pixelFormat: GlyphAtlasPixelFormat
    /// Pixel bounding box (x, y, width, height) inside the atlas page.
    public let rect: CGRect
    /// Normalized texture coordinates (u, v, uWidth, vHeight) in 0.0...1.0 space.
    public let uvRect: CGRect
    /// Offset in points relative to the baseline origin to position the glyph quad.
    public let bearing: CGPoint
    /// Horizontal and vertical advance in points.
    public let advance: CGSize
    /// Pixel width of the rasterized mask.
    public let pixelWidth: Int
    /// Pixel height of the rasterized mask.
    public let pixelHeight: Int
    /// True if the glyph has no visible pixel representation (e.g. whitespace).
    public let isEmpty: Bool
    /// True if the glyph mask was rasterized and packed into an atlas page.
    public let isRasterized: Bool

    public init(
        key: GlyphAtlasKey,
        pageIndex: Int,
        pixelFormat: GlyphAtlasPixelFormat? = nil,
        rect: CGRect,
        uvRect: CGRect,
        bearing: CGPoint,
        advance: CGSize,
        pixelWidth: Int,
        pixelHeight: Int,
        isEmpty: Bool,
        isRasterized: Bool
    ) {
        self.key = key
        self.pageIndex = pageIndex
        self.pixelFormat = pixelFormat ?? key.pixelFormat
        self.rect = rect
        self.uvRect = uvRect
        self.bearing = bearing
        self.advance = advance
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isEmpty = isEmpty
        self.isRasterized = isRasterized
    }
}
