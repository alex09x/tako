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
import CoreText

extension Tako {
    /// Text layout for the drawn tab strip.
    ///
    /// `NSString.size(withAttributes:)` asks CoreText to discover fallback
    /// fonts. On macOS 15 that path can raise an Objective-C exception when a
    /// rapidly changing OSC title contains a glyph missing from SF Mono (the
    /// braille spinner used by several CLI tools is one example). Objective-C
    /// exceptions cannot be caught by Swift, so one title used to terminate
    /// the whole application.
    ///
    /// Resolve unsupported graphemes ourselves, then measure and draw glyphs
    /// directly. This avoids both the fallback-font dictionary and repeated
    /// attributed-string layout in every title-bar draw pass.
    @MainActor
    enum TabText {
        static let replacement = "?"

        static func displayText(_ text: String, font: NSFont) -> String {
            var result = ""
            text.enumerateSubstrings(
                in: text.startIndex..<text.endIndex,
                options: .byComposedCharacterSequences
            ) { substring, _, _, _ in
                guard let substring else { return }
                result += hasGlyphs(for: substring, font: font) ? substring : replacement
            }
            return result
        }

        static func width(of text: String, font: NSFont) -> CGFloat {
            glyphRun(for: text, font: font).width
        }

        static func height(for font: NSFont) -> CGFloat {
            ceil(font.ascender - font.descender + font.leading)
        }

        static func truncate(_ text: String, to maxWidth: CGFloat, font: NSFont) -> String {
            guard maxWidth > 0 else { return "" }
            let safe = displayText(text, font: font)
            guard width(of: safe, font: font) > maxWidth else { return safe }

            let ellipsis = hasGlyphs(for: "\u{2026}", font: font) ? "\u{2026}" : "..."
            let ellipsisWidth = width(of: ellipsis, font: font)
            guard ellipsisWidth <= maxWidth else { return "" }

            var result = ""
            for character in safe {
                let candidate = result + String(character)
                if width(of: candidate, font: font) + ellipsisWidth > maxWidth { break }
                result = candidate
            }
            return result + ellipsis
        }

        @discardableResult
        static func draw(
            _ text: String,
            atX x: CGFloat,
            centeredAtY centerY: CGFloat,
            font: NSFont,
            color: NSColor,
            context: CGContext
        ) -> CGFloat {
            let run = glyphRun(for: text, font: font)
            guard !run.glyphs.isEmpty else { return 0 }

            let baseline = centerY - (font.ascender + font.descender) / 2
            var positions: [CGPoint] = []
            positions.reserveCapacity(run.glyphs.count)
            var cursor = x
            for advance in run.advances {
                positions.append(CGPoint(x: cursor, y: baseline))
                cursor += advance.width
            }

            context.saveGState()
            context.textMatrix = .identity
            context.setFillColor(color.cgColor)
            CTFontDrawGlyphs(font as CTFont, run.glyphs, positions, run.glyphs.count, context)
            context.restoreGState()
            return run.width
        }

        private struct GlyphRun {
            let glyphs: [CGGlyph]
            let advances: [CGSize]
            let width: CGFloat
        }

        private static func hasGlyphs(for text: String, font: NSFont) -> Bool {
            let characters = Array(text.utf16)
            guard !characters.isEmpty else { return true }
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            return characters.withUnsafeBufferPointer { chars in
                glyphs.withUnsafeMutableBufferPointer { output in
                    CTFontGetGlyphsForCharacters(
                        font as CTFont,
                        chars.baseAddress!,
                        output.baseAddress!,
                        characters.count
                    )
                }
            } && !glyphs.contains(0)
        }

        private static func glyphRun(for text: String, font: NSFont) -> GlyphRun {
            let safe = displayText(text, font: font)
            let characters = Array(safe.utf16)
            guard !characters.isEmpty else {
                return GlyphRun(glyphs: [], advances: [], width: 0)
            }

            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            characters.withUnsafeBufferPointer { chars in
                glyphs.withUnsafeMutableBufferPointer { output in
                    _ = CTFontGetGlyphsForCharacters(
                        font as CTFont,
                        chars.baseAddress!,
                        output.baseAddress!,
                        characters.count
                    )
                }
            }

            // `displayText` guarantees this should not be needed. Keep the
            // direct drawing path total even if a font changes under us.
            if glyphs.contains(0) {
                let fallback = Array(replacement.utf16)
                var fallbackGlyph = [CGGlyph](repeating: 0, count: fallback.count)
                fallback.withUnsafeBufferPointer { chars in
                    fallbackGlyph.withUnsafeMutableBufferPointer { output in
                        _ = CTFontGetGlyphsForCharacters(
                            font as CTFont,
                            chars.baseAddress!,
                            output.baseAddress!,
                            fallback.count
                        )
                    }
                }
                let replacementGlyph = fallbackGlyph.first ?? 0
                glyphs = glyphs.map { $0 == 0 ? replacementGlyph : $0 }
            }

            var advances = [CGSize](repeating: .zero, count: glyphs.count)
            glyphs.withUnsafeBufferPointer { input in
                advances.withUnsafeMutableBufferPointer { output in
                    _ = CTFontGetAdvancesForGlyphs(
                        font as CTFont,
                        .horizontal,
                        input.baseAddress!,
                        output.baseAddress!,
                        glyphs.count
                    )
                }
            }
            let measured = advances.reduce(CGFloat.zero) { $0 + $1.width }
            return GlyphRun(glyphs: glyphs, advances: advances, width: measured)
        }
    }
}
