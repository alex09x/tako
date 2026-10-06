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

extension TerminalMetalFramePlanner {
    /// A draw binds one atlas page, so instances are grouped by page. Almost
    /// every frame has exactly one page and skips the sort entirely.
    func finishGlyphPass() {
        groupGlyphs(&glyphInstances, into: &glyphPageRanges)
        groupGlyphs(&colorGlyphInstances, into: &colorGlyphPageRanges)
    }

    func groupGlyphs(
        _ instances: inout [TerminalMetalGlyphInstance],
        into ranges: inout [(page: Int, range: Range<Int>)]
    ) {
        guard !instances.isEmpty else { return }
        let firstPage = instances[0].atlasPage
        if instances.contains(where: { $0.atlasPage != firstPage }) {
            instances.sort { $0.atlasPage < $1.atlasPage }
        }
        var start = 0
        var page = instances[0].atlasPage
        for index in 1..<instances.count where instances[index].atlasPage != page {
            ranges.append((page: Int(page), range: start..<index))
            start = index
            page = instances[index].atlasPage
        }
        ranges.append((page: Int(page), range: start..<instances.count))
    }

    /// Resolves symbolic style first, then CoreText fallback for the scalar.
    public func resolvedFontName(for scalar: UInt32, bold: Bool = false, italic: Bool = false) -> String? {
        guard let resolved = resolveGlyph(for: scalar, bold: bold, italic: italic) else { return nil }
        return CTFontCopyPostScriptName(resolved.font) as String
    }

    func resolveGlyph(for scalar: UInt32, bold: Bool, italic: Bool) -> ResolvedGlyph? {
        let traits = UInt8(bold ? 1 : 0) | UInt8(italic ? 2 : 0)
        let key = StyledScalar(scalar: scalar, traits: traits)
        if let cached = resolvedGlyphs[key] { return cached }
        guard let unicodeScalar = UnicodeScalar(scalar) else { return nil }
        let string = String(unicodeScalar)
        let (base, synthetic) = baseFace(bold: bold, italic: italic)
        var result = metrics.shapesGlyphs ? Self.shapedGlyph(string, font: base) : nil
        if result == nil {
            let utf16 = Array(string.utf16)
            let fallback = CTFontCreateForString(base, string as CFString, CFRange(location: 0, length: utf16.count))
            var glyphs = [CGGlyph](repeating: 0, count: max(utf16.count, 1))
            let ok = CTFontGetGlyphsForCharacters(fallback, utf16, &glyphs, utf16.count)
            result = ok && glyphs.first != 0 ? (fallback, glyphs[0]) : nil
        }
        let resolved = result.map { found in
            ResolvedGlyph(
                font: found.0,
                glyph: found.1,
                emboldened: synthetic && CTFontCopyPostScriptName(found.0) == CTFontCopyPostScriptName(base)
            )
        }
        resolvedGlyphs[key] = resolved
        return resolved
    }

    /// The face for a style, and whether it is a synthesised bold.
    func baseFace(bold: Bool, italic: Bool) -> (font: CTFont, synthetic: Bool) {
        switch (bold, italic) {
        case (true, true):
            return (metrics.boldItalicFont ?? metrics.boldFont ?? metrics.italicFont ?? metrics.font,
                    metrics.boldItalicIsSynthetic)
        case (true, false):
            return (metrics.boldFont ?? metrics.font, metrics.boldIsSynthetic)
        case (false, true):
            return (metrics.italicFont ?? metrics.font, false)
        case (false, false):
            return (metrics.font, false)
        }
    }

    /// The glyph CoreText's shaper picks for `string`, which is where the
    /// font's feature settings (`ss01`, `zero`) take effect.
    static func shapedGlyph(_ string: String, font: CTFont) -> (CTFont, CGGlyph)? {
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, string as CFString, [kCTFontAttributeName: font] as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first, CTRunGetGlyphCount(run) > 0 else {
            return nil
        }
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard glyph != 0, let runFont = attributes[kCTFontAttributeName] else { return nil }
        return (runFont as! CTFont, glyph)
    }
}
