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

/// A reusable glyph atlas that rasterizes CoreText glyphs into packed 8-bit grayscale texture pages once,
/// caching results and exposing stable atlas coordinates for Metal text rendering.
public final class GlyphAtlas: @unchecked Sendable {
    public let pageSize: CGSize
    public let padding: Int

    var pages: [GlyphAtlasPage] = []
    var cache: [GlyphAtlasKey: GlyphAtlasEntry] = [:]

    struct ClusterRequest: Hashable {
        let text: String
        let fontName: String
        let fontSize: CGFloat
        let skew: CGFloat
        let scale: CGFloat
        let emboldened: Bool
    }
    var clusterCache: [ClusterRequest: GlyphAtlasEntry] = [:]
    /// Changes whenever any page changes or the atlas is cleared.
    public internal(set) var generation: UInt64 = 0

    /// Total number of unique glyph variants currently cached in the atlas.
    public var cachedCount: Int { cache.count + clusterCache.count }

    public init(pageSize: CGSize = CGSize(width: 1024, height: 1024), padding: Int = 1) {
        self.pageSize = pageSize
        self.padding = padding
    }

    /// Stroke width, in points, that thickens a synthesised bold.
    public static func syntheticBoldStrokeWidth(fontSize: CGFloat) -> CGFloat {
        fontSize / 14
    }

    /// Checks if a glyph entry is already cached in the atlas.
    public func contains(glyph: CGGlyph, font: CTFont, scale: CGFloat = 1.0, emboldened: Bool = false) -> Bool {
        let key = GlyphAtlasKey(glyph: glyph, font: font, scale: scale, emboldened: emboldened)
        return cache[key] != nil
    }

    /// Looks up or rasterizes a CoreText glyph, returning a stable `GlyphAtlasEntry`.
    /// `emboldened` thickens it, for a bold the font does not have.
    public func glyphEntry(
        for glyph: CGGlyph,
        font: CTFont,
        scale: CGFloat = 1.0,
        emboldened: Bool = false
    ) -> GlyphAtlasEntry {
        let key = GlyphAtlasKey(glyph: glyph, font: font, scale: scale, emboldened: emboldened)
        if let existing = cache[key] {
            return existing
        }

        let entry = rasterizeAndPack(key: key, font: font)
        cache[key] = entry
        return entry
    }

    /// Convenience lookup by character for a font and scale factor.
    public func glyphEntry(for character: Character, font: CTFont, scale: CGFloat = 1.0) -> GlyphAtlasEntry? {
        let utf16 = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), let firstGlyph = glyphs.first else {
            return nil
        }
        return glyphEntry(for: firstGlyph, font: font, scale: scale)
    }

    /// Looks up or rasterizes a grapheme cluster shaped with CoreText from
    /// `font`, falling back per run as CoreText does, into one entry. The
    /// entry is colour when any run's font is a colour font. `emboldened`
    /// thickens only the runs drawn in `font` itself.
    public func clusterEntry(
        for text: String,
        font: CTFont,
        scale: CGFloat = 1.0,
        emboldened: Bool = false
    ) -> GlyphAtlasEntry {
        let request = ClusterRequest(
            text: text,
            fontName: CTFontCopyPostScriptName(font) as String,
            fontSize: CTFontGetSize(font),
            skew: CTFontGetMatrix(font).c,
            scale: scale,
            emboldened: emboldened
        )
        if let existing = clusterCache[request] {
            return existing
        }
        let entry = rasterizeAndPackCluster(request: request, font: font)
        clusterCache[request] = entry
        return entry
    }

    /// Resets all pages and clears the glyph cache.
    public func clear() {
        pages.removeAll()
        cache.removeAll()
        clusterCache.removeAll()
        generation &+= 1
    }

    /// Returns the raw 8-bit grayscale pixel data for a given page index.
    public func textureData(pageIndex: Int) -> Data? {
        guard pageIndex >= 0, pageIndex < pages.count else { return nil }
        return pages[pageIndex].data
    }

    /// Generates a CGImage representation of an atlas page for rendering or inspection.
    public func cgImage(pageIndex: Int) -> CGImage? {
        guard pageIndex >= 0, pageIndex < pages.count else { return nil }
        let page = pages[pageIndex]
        let colorSpace = page.pixelFormat == .grayscale8
            ? CGColorSpaceCreateDeviceGray()
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let provider = CGDataProvider(data: page.data as CFData) else { return nil }
        let bitmapInfo: CGBitmapInfo = page.pixelFormat == .grayscale8
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            : [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        return CGImage(
            width: page.width,
            height: page.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * page.pixelFormat.bytesPerPixel,
            bytesPerRow: page.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
