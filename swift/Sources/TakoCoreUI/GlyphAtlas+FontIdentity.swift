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

extension GlyphAtlas {
    /// CTFont is immutable. Retaining it prevents an object identifier from
    /// being recycled while the extracted identity is still cached.
    struct FontIdentity {
        let font: CTFont
        let name: String
        let size: CGFloat
        let skew: CGFloat
        let pixelFormat: GlyphAtlasPixelFormat
        let variations: [GlyphAtlasKey.Variation]
    }

    func fontIdentity(for font: CTFont) -> FontIdentity {
        let id = ObjectIdentifier(font)
        if let cached = fontIdentities[id] { return cached }
        // Fallback faces can be numerous in an arbitrary Unicode transcript.
        // Bound retained fonts independently of the atlas's glyph storage.
        if fontIdentities.count >= 128 { fontIdentities.removeAll(keepingCapacity: true) }
        let identity = FontIdentity(
            font: font,
            name: CTFontCopyPostScriptName(font) as String,
            size: CTFontGetSize(font),
            skew: CTFontGetMatrix(font).c,
            pixelFormat: GlyphAtlasKey.isColorFont(font) ? .bgra8Premultiplied : .grayscale8,
            variations: GlyphAtlasKey.variations(of: font)
        )
        fontIdentityReadCount += 1
        fontIdentities[id] = identity
        return identity
    }

    func glyphKey(_ glyph: CGGlyph, font: CTFont, scale: CGFloat, emboldened: Bool) -> GlyphAtlasKey {
        let identity = fontIdentity(for: font)
        return GlyphAtlasKey(
            glyph: glyph,
            fontName: identity.name,
            fontSize: identity.size,
            scale: scale,
            pixelFormat: identity.pixelFormat,
            skew: identity.skew,
            emboldened: emboldened,
            variations: identity.variations
        )
    }
}
