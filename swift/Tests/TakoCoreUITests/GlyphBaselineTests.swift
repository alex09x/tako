import CoreGraphics
import CoreText
import XCTest
@testable import TakoCoreUI

/// Every glyph's mask starts on a whole device pixel. Ink begins a fraction
/// of a pixel from the baseline, different per glyph; masks that kept the
/// fraction were each shifted by their own remainder when drawn on whole
/// pixels, so neighbouring letters -- Cyrillic ones especially -- stood up to
/// a pixel higher or lower than each other.
final class GlyphBaselineTests: XCTestCase {
    private let text = "Привет, уйдёт рыба! Hello gjpq"

    private func assertWholePixels(font: CTFont, scale: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let atlas = GlyphAtlas(pageSize: CGSize(width: 1024, height: 1024))
        for ch in text where ch != " " {
            let utf16 = Array(String(ch).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) else { continue }
            let entry = atlas.glyphEntry(for: glyphs[0], font: font, scale: scale)
            guard entry.isRasterized else { continue }
            for (name, value) in [("x", entry.bearing.x), ("y", entry.bearing.y)] {
                let pixels = value * scale
                XCTAssertEqual(pixels, pixels.rounded(), accuracy: 1e-6,
                               "\(ch) bearing.\(name) at scale \(scale) is \(pixels) px", file: file, line: line)
            }
        }
    }

    func testBearingsAreWholePixelsAtRetinaAndFractionalScales() {
        for name in ["Menlo-Regular", "Helvetica"] {
            let font = CTFontCreateWithName(name as CFString, 13.5, nil)
            for scale: CGFloat in [1, 2, 1.5, 3] {
                assertWholePixels(font: font, scale: scale)
            }
        }
    }

    func testPixelAlignedOnlyGrowsTheRect() {
        let rect = CGRect(x: 0.3, y: -2.7, width: 5.1, height: 9.25)
        let aligned = GlyphAtlas.pixelAligned(rect, scale: 2)
        XCTAssertTrue(aligned.contains(rect))
        XCTAssertEqual(aligned.minY * 2, (aligned.minY * 2).rounded())
        XCTAssertEqual(aligned.maxX * 2, (aligned.maxX * 2).rounded())
        XCTAssertLessThan(aligned.height - rect.height, 1)
    }
}
