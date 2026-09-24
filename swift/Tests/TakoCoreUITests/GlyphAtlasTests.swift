import XCTest
import CoreGraphics
import CoreText
@testable import TakoCoreUI

final class GlyphAtlasTests: XCTestCase {

    func testCacheReuse() {
        let atlas = GlyphAtlas(pageSize: CGSize(width: 512, height: 512))
        let font = CTFontCreateWithName("Helvetica" as CFString, 16.0, nil)

        let utf16 = Array("A".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count))
        let glyph = glyphs[0]

        XCTAssertFalse(atlas.contains(glyph: glyph, font: font, scale: 2.0))
        XCTAssertEqual(atlas.cachedCount, 0)

        // First lookup: should rasterize and cache
        let entry1 = atlas.glyphEntry(for: glyph, font: font, scale: 2.0)
        XCTAssertTrue(atlas.contains(glyph: glyph, font: font, scale: 2.0))
        XCTAssertEqual(atlas.cachedCount, 1)

        // Second lookup: should return cached entry without increasing cachedCount
        let entry2 = atlas.glyphEntry(for: glyph, font: font, scale: 2.0)
        XCTAssertEqual(atlas.cachedCount, 1)
        XCTAssertEqual(entry1, entry2)
        XCTAssertEqual(atlas.generation, 1)
        XCTAssertEqual(atlas.pages[0].generation, 1)
    }

    func testNonEmptyRasterizedGlyphs() {
        let atlas = GlyphAtlas(pageSize: CGSize(width: 512, height: 512))
        let font = CTFontCreateWithName("Helvetica" as CFString, 24.0, nil)

        guard let entry = atlas.glyphEntry(for: "M", font: font, scale: 2.0) else {
            XCTFail("Failed to create entry for character M")
            return
        }

        XCTAssertFalse(entry.isEmpty)
        XCTAssertTrue(entry.isRasterized)
        XCTAssertGreaterThan(entry.pixelWidth, 0)
        XCTAssertGreaterThan(entry.pixelHeight, 0)
        XCTAssertGreaterThan(entry.uvRect.width, 0)
        XCTAssertGreaterThan(entry.uvRect.height, 0)
        XCTAssertGreaterThan(entry.advance.width, 0)

        XCTAssertEqual(atlas.pages.count, 1)
        guard let pixelData = atlas.textureData(pageIndex: entry.pageIndex) else {
            XCTFail("Missing page texture data")
            return
        }

        // Verify that the rasterized pixel mask contains non-zero grayscale intensity
        let hasNonZeroPixels = pixelData.contains(where: { $0 > 0 })
        XCTAssertTrue(hasNonZeroPixels, "Rasterized glyph mask should contain non-zero pixel intensity")

        let image = atlas.cgImage(pageIndex: entry.pageIndex)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 512)
        XCTAssertEqual(image?.height, 512)
    }

    func testEmptyGlyphForWhitespace() {
        let atlas = GlyphAtlas(pageSize: CGSize(width: 512, height: 512))
        let font = CTFontCreateWithName("Helvetica" as CFString, 16.0, nil)

        guard let entry = atlas.glyphEntry(for: " ", font: font, scale: 1.0) else {
            XCTFail("Failed to create entry for space character")
            return
        }

        XCTAssertTrue(entry.isEmpty)
        XCTAssertFalse(entry.isRasterized)
        XCTAssertEqual(entry.pixelWidth, 0)
        XCTAssertEqual(entry.pixelHeight, 0)
        XCTAssertGreaterThan(entry.advance.width, 0)
    }

    func testAtlasPageAllocationOnOverflow() {
        let smallAtlas = GlyphAtlas(pageSize: CGSize(width: 32, height: 32), padding: 1)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20.0, nil)

        let characters: [Character] = ["A", "B", "C", "D", "E", "F", "G", "H"]
        for char in characters {
            _ = smallAtlas.glyphEntry(for: char, font: font, scale: 2.0)
        }

        XCTAssertGreaterThan(smallAtlas.pages.count, 1, "Atlas should allocate new pages when a page fills up")
    }

    func testClearAtlas() {
        let atlas = GlyphAtlas(pageSize: CGSize(width: 512, height: 512))
        let font = CTFontCreateWithName("Helvetica" as CFString, 16.0, nil)

        _ = atlas.glyphEntry(for: "A", font: font, scale: 1.0)
        _ = atlas.glyphEntry(for: "B", font: font, scale: 1.0)
        XCTAssertEqual(atlas.cachedCount, 2)
        XCTAssertFalse(atlas.pages.isEmpty)

        atlas.clear()
        XCTAssertEqual(atlas.cachedCount, 0)
        XCTAssertTrue(atlas.pages.isEmpty)
        XCTAssertEqual(atlas.generation, 3)
    }

    func testPageGenerationChangesOnlyWhenPixelsChange() throws {
        let atlas = GlyphAtlas(pageSize: CGSize(width: 256, height: 256))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let first = try XCTUnwrap(atlas.glyphEntry(for: "A", font: font))
        let generation = atlas.pages[first.pageIndex].generation
        _ = atlas.glyphEntry(for: "A", font: font)
        XCTAssertEqual(atlas.pages[first.pageIndex].generation, generation)
        _ = atlas.glyphEntry(for: "B", font: font)
        XCTAssertGreaterThan(atlas.pages[first.pageIndex].generation, generation)
    }

    func testColorEmojiUsesPremultipliedBGRAAtlasPixels() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("AppleColorEmoji rasterization is unavailable to the standalone Simulator test process; run this pixel assertion on device")
        #endif
        let atlas = GlyphAtlas(pageSize: CGSize(width: 256, height: 256))
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 32, nil)
        let entry = try XCTUnwrap(atlas.glyphEntry(for: "😀", font: font, scale: 1))
        XCTAssertEqual(entry.pixelFormat, .bgra8Premultiplied)
        let page = atlas.pages[entry.pageIndex]
        XCTAssertEqual(page.pixelFormat, .bgra8Premultiplied)
        XCTAssertEqual(page.bytesPerRow, page.width * 4)
        let bytes = [UInt8](page.data)
        var sawColoredPixel = false
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 0 {
            if bytes[offset] != bytes[offset + 1] || bytes[offset + 1] != bytes[offset + 2] {
                sawColoredPixel = true
                break
            }
        }
        XCTAssertTrue(sawColoredPixel)
    }
}
