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

extension TerminalRenderer {
    /// Cell metrics derived from the font, so the grid and the glyphs agree.
    public struct Metrics {
        public let cellWidth: CGFloat
        public let cellHeight: CGFloat
        /// Points from the bottom of a cell up to the text baseline.
        public let baseline: CGFloat
        public let font: CTFont
        /// Faces for SGR bold, italic and both.
        public let boldFont: CTFont
        public let italicFont: CTFont
        public let boldItalicFont: CTFont
        /// Bold drawn by thickening a face that has no bold weight.
        public let boldIsSynthetic: Bool
        public let boldItalicIsSynthetic: Bool
        /// Points from the top of a cell down to the top of the underline.
        public let underlinePosition: CGFloat
        public let underlineThickness: CGFloat
        /// Whether `font-feature` settings apply.
        public let hasFontFeatures: Bool

        /// Slant given to a synthesised italic, as the font matrix's `c`.
        static let syntheticItalicSkew: CGFloat = 0.2

        public init(
            fontSize: CGFloat,
            fontName: String? = nil,
            cellWidth: CGFloat? = nil,
            cellHeight: CGFloat? = nil
        ) {
            self.init(theme: TerminalTheme(
                fontFamily: fontName,
                fontSize: fontSize,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            ))
        }

        public init(theme: TerminalTheme) {
            let fontSize = theme.fontSize
            let base = Self.resolveFont(named: theme.fontFamily, size: fontSize)
            let regular = Self.namedFace(theme.fontStyle, like: base) ?? base

            let glyph = CTFontGetGlyphWithName(regular, "M" as CFString)
            var advance = CGSize.zero
            var glyphs = [glyph]
            CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyphs, &advance, 1)
            let ascent = CTFontGetAscent(regular)
            let descent = CTFontGetDescent(regular)
            let leading = CTFontGetLeading(regular)
            var width = ceil(advance.width)
            var height = ceil(ascent + descent + leading)
            if let cellWidth = theme.cellWidth, cellWidth.isFinite, cellWidth > 0 {
                width = cellWidth
            }
            if let cellHeight = theme.cellHeight, cellHeight.isFinite, cellHeight > 0 {
                height = cellHeight
            }
            var baseline = ceil(descent + leading)
            var underlinePosition = height - baseline + 1
            var underlineThickness: CGFloat = 1

            if let modifier = theme.adjustCellWidth {
                width = max(modifier.apply(to: width), 1)
            }
            if let modifier = theme.adjustCellHeight {
                let adjusted = max(modifier.apply(to: height), 1)
                let shift = ((adjusted - height) / 2).rounded(.down)
                baseline += shift
                underlinePosition += shift
                height = adjusted
            }
            if let modifier = theme.adjustFontBaseline {
                baseline = max(modifier.apply(to: baseline), 0)
            }
            if let modifier = theme.adjustUnderlinePosition {
                underlinePosition = max(modifier.apply(to: underlinePosition), 0)
            }
            if let modifier = theme.adjustUnderlineThickness {
                underlineThickness = max(modifier.apply(to: underlineThickness), 1)
            }
            self.cellWidth = width
            self.cellHeight = height
            self.baseline = baseline
            self.underlinePosition = underlinePosition
            self.underlineThickness = underlineThickness

            let synthetic = theme.fontSyntheticStyle
            let bold = Self.styledFace(
                traits: .traitBold, family: theme.fontFamilyBold, style: theme.fontStyleBold,
                regular: regular, synthesise: synthetic.contains(.bold))
            let italic = Self.styledFace(
                traits: .traitItalic, family: theme.fontFamilyItalic, style: theme.fontStyleItalic,
                regular: regular, synthesise: synthetic.contains(.italic))
            let boldItalic = Self.styledFace(
                traits: [.traitBold, .traitItalic], family: theme.fontFamilyBoldItalic,
                style: theme.fontStyleBoldItalic, regular: regular,
                synthesise: synthetic.contains(.boldItalic))

            let features = Self.featureDescriptor(theme.fontFeatures)
            func withFeatures(_ font: CTFont) -> CTFont {
                features.map { CTFontCreateCopyWithAttributes(font, fontSize, nil, $0) } ?? font
            }
            self.font = withFeatures(regular)
            self.boldFont = withFeatures(bold.font)
            self.italicFont = withFeatures(italic.font)
            self.boldItalicFont = withFeatures(boldItalic.font)
            self.boldIsSynthetic = bold.emboldened
            self.boldItalicIsSynthetic = boldItalic.emboldened
            self.hasFontFeatures = features != nil
        }

        static func resolveFont(named fontName: String?, size fontSize: CGFloat) -> CTFont {
            let candidates = fontName.map { name in
                var candidates = [name, name + "-Regular"]
                if name.lowercased().hasSuffix("-regular") {
                    candidates.append(String(name.dropLast("-Regular".count)))
                }
                return candidates
            } ?? [
                "JetBrainsMonoNF-Regular",
                "JetBrainsMono-Regular",
                "JetBrains Mono",
                "SFMono-Regular",
                "Menlo",
            ]
            return firstMatch(candidates, size: fontSize)
                ?? CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        }

        private static func firstMatch(_ names: [String], size: CGFloat) -> CTFont? {
            for name in names {
                let candidate = CTFontCreateWithName(name as CFString, size, nil)
                if Self.matchesRequestedName(candidate, requested: name) {
                    return candidate
                }
            }
            return nil
        }

        static func namedFace(_ style: TerminalTheme.FontStyle, like font: CTFont) -> CTFont? {
            guard case .named(let name) = style else { return nil }
            let family = CTFontCopyFamilyName(font) as String
            let descriptor = CTFontDescriptorCreateWithAttributes([
                kCTFontFamilyNameAttribute: family,
                kCTFontStyleNameAttribute: name,
            ] as CFDictionary)
            let mandatory: Set<String> = [kCTFontFamilyNameAttribute as String, kCTFontStyleNameAttribute as String]
            guard let match = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, mandatory as CFSet) else {
                return nil
            }
            let face = CTFontCreateWithFontDescriptor(match, CTFontGetSize(font), nil)
            let style = CTFontCopyName(face, kCTFontStyleNameKey).map { $0 as String } ?? ""
            guard normalizedFontName(CTFontCopyFamilyName(face) as String) == normalizedFontName(family),
                  normalizedFontName(style) == normalizedFontName(name) else { return nil }
            return face
        }

        private static func styledFace(
            traits: CTFontSymbolicTraits,
            family: String?,
            style: TerminalTheme.FontStyle,
            regular: CTFont,
            synthesise: Bool
        ) -> (font: CTFont, emboldened: Bool) {
            if style == .disabled { return (regular, false) }
            let size = CTFontGetSize(regular)
            let base = family.flatMap { firstMatch([$0, $0 + "-Regular"], size: size) } ?? regular
            if let named = namedFace(style, like: base) { return (named, false) }
            if let face = traitFace(base, traits) { return (face, false) }
            guard synthesise else { return (regular, false) }

            let wantsBold = traits.contains(.traitBold)
            let wantsItalic = traits.contains(.traitItalic)
            var font = base
            var emboldened = wantsBold
            var slanted = wantsItalic
            if wantsBold, wantsItalic {
                if let bold = traitFace(base, .traitBold) {
                    font = bold
                    emboldened = false
                } else if let italic = traitFace(base, .traitItalic) {
                    font = italic
                    slanted = false
                }
            }
            if slanted {
                var skew = CGAffineTransform(a: 1, b: 0, c: syntheticItalicSkew, d: 1, tx: 0, ty: 0)
                font = CTFontCreateCopyWithAttributes(font, size, &skew, nil)
            }
            return (font, emboldened)
        }

        private static func traitFace(_ font: CTFont, _ traits: CTFontSymbolicTraits) -> CTFont? {
            guard let face = CTFontCreateCopyWithSymbolicTraits(font, CTFontGetSize(font), nil, traits, traits),
                  CTFontGetSymbolicTraits(face).contains(traits),
                  CTFontCopyFamilyName(face) as String == CTFontCopyFamilyName(font) as String else {
                return nil
            }
            return face
        }

        private static func featureDescriptor(_ features: [TerminalTheme.FontFeature]) -> CTFontDescriptor? {
            guard !features.isEmpty else { return nil }
            let settings = features.map {
                [kCTFontOpenTypeFeatureTag: $0.tag, kCTFontOpenTypeFeatureValue: $0.value] as [CFString: Any]
            }
            return CTFontDescriptorCreateWithAttributes(
                [kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
        }

        public func face(bold: Bool, italic: Bool) -> (font: CTFont, emboldened: Bool) {
            switch (bold, italic) {
            case (true, true): return (boldItalicFont, boldItalicIsSynthetic)
            case (true, false): return (boldFont, boldIsSynthetic)
            case (false, true): return (italicFont, false)
            case (false, false): return (font, false)
            }
        }

        private static func matchesRequestedName(_ font: CTFont, requested: String) -> Bool {
            let requested = normalizedFontName(requested)
            let identities = [
                CTFontCopyPostScriptName(font) as String,
                CTFontCopyFamilyName(font) as String,
                CTFontCopyFullName(font) as String,
            ]
            return identities.contains { normalizedFontName($0) == requested }
        }

        private static func normalizedFontName(_ name: String) -> String {
            name.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
                .joined()
                .lowercased()
        }
    }
}
