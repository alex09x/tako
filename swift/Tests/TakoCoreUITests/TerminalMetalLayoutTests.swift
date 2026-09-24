import XCTest
import simd
@testable import TakoCoreUI

final class TerminalMetalLayoutTests: XCTestCase {
    func testPassOrderingMatchesExpectedUpstreamOrdering() {
        XCTAssertEqual(TerminalMetalRenderPass.ordered, [
            .background,
            .selection,
            .cursor,
            .grayscaleGlyph,
            .colorGlyph,
            .decoration,
        ])
    }

    func testBackgroundInstanceLayoutIsDeterministic() {
        XCTAssertEqual(MemoryLayout<TerminalMetalBackgroundInstance>.size, 32)
        XCTAssertEqual(MemoryLayout<TerminalMetalBackgroundInstance>.alignment, 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalBackgroundInstance>.stride, 32)
        XCTAssertEqual(MemoryLayout<TerminalMetalBackgroundInstance>.offset(of: \.rect), 0)
        XCTAssertEqual(MemoryLayout<TerminalMetalBackgroundInstance>.offset(of: \.color), 16)
    }

    func testSelectionInstanceLayoutMatchesBackgroundLayout() {
        XCTAssertEqual(MemoryLayout<TerminalMetalSelectionInstance>.size, 32)
        XCTAssertEqual(MemoryLayout<TerminalMetalSelectionInstance>.alignment, 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalSelectionInstance>.stride, 32)
        XCTAssertEqual(MemoryLayout<TerminalMetalSelectionInstance>.offset(of: \.rect), 0)
        XCTAssertEqual(MemoryLayout<TerminalMetalSelectionInstance>.offset(of: \.color), 16)
    }

    func testCursorInstanceLayoutAndFlagsAreDeterministic() {
        XCTAssertEqual(MemoryLayout<TerminalMetalCursorInstance>.size, 48)
        XCTAssertEqual(MemoryLayout<TerminalMetalCursorInstance>.alignment, 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalCursorInstance>.offset(of: \.rect), 0)
        XCTAssertEqual(MemoryLayout<TerminalMetalCursorInstance>.offset(of: \.shape), 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalCursorInstance>.offset(of: \.blinkState), 20)
        XCTAssertEqual(MemoryLayout<TerminalMetalCursorInstance>.offset(of: \.color), 32)
    }

    func testGlyphInstanceLayoutForGrayscaleAtlasPass() {
        XCTAssertEqual(MemoryLayout<TerminalMetalGlyphInstance>.size, 64)
        XCTAssertEqual(MemoryLayout<TerminalMetalGlyphInstance>.alignment, 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalGlyphInstance>.stride, 64)
        XCTAssertEqual(MemoryLayout<TerminalMetalGlyphInstance>.offset(of: \.destRect), 0)
        XCTAssertEqual(MemoryLayout<TerminalMetalGlyphInstance>.offset(of: \.uvRect), 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalGlyphInstance>.offset(of: \.color), 32)
        XCTAssertEqual(MemoryLayout<TerminalMetalGlyphInstance>.offset(of: \.atlasPage), 48)
        XCTAssertEqual(MemoryLayout<TerminalMetalGlyphInstance>.offset(of: \.flags), 52)
        XCTAssertEqual(MemoryLayout<TerminalMetalGlyphInstance>.offset(of: \._pad), 56)
    }

    func testImageInstanceLayoutForKittyGraphicsPass() {
        XCTAssertEqual(MemoryLayout<TerminalMetalImageInstance>.size, 64)
        XCTAssertEqual(MemoryLayout<TerminalMetalImageInstance>.alignment, 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalImageInstance>.stride, 64)
        XCTAssertEqual(MemoryLayout<TerminalMetalImageInstance>.offset(of: \.destRect), 0)
        XCTAssertEqual(MemoryLayout<TerminalMetalImageInstance>.offset(of: \.uvRect), 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalImageInstance>.offset(of: \.tint), 32)
        XCTAssertEqual(MemoryLayout<TerminalMetalImageInstance>.offset(of: \.imageId), 48)
        XCTAssertEqual(MemoryLayout<TerminalMetalImageInstance>.offset(of: \.flags), 52)
        XCTAssertEqual(MemoryLayout<TerminalMetalImageInstance>.offset(of: \._pad), 56)
    }

    func testDecorationInstanceLayoutIsDeterministic() {
        XCTAssertEqual(MemoryLayout<TerminalMetalDecorationInstance>.size, 48)
        XCTAssertEqual(MemoryLayout<TerminalMetalDecorationInstance>.alignment, 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalDecorationInstance>.stride, 48)
        XCTAssertEqual(MemoryLayout<TerminalMetalDecorationInstance>.offset(of: \.rect), 0)
        XCTAssertEqual(MemoryLayout<TerminalMetalDecorationInstance>.offset(of: \.color), 16)
        XCTAssertEqual(MemoryLayout<TerminalMetalDecorationInstance>.offset(of: \.style), 32)
        XCTAssertEqual(MemoryLayout<TerminalMetalDecorationInstance>.offset(of: \.thickness), 36)
        XCTAssertEqual(MemoryLayout<TerminalMetalDecorationInstance>.offset(of: \._pad), 40)
    }

    func testKittyImagePassDrawsBetweenSelectionAndGlyphs() {
        XCTAssertEqual(TerminalMetalRenderPass.orderedWithImages, [
            .background,
            .selection,
            .kittyImage,
            .cursor,
            .grayscaleGlyph,
            .colorGlyph,
            .decoration,
        ])
        XCTAssertEqual(TerminalMetalImageInstance.pass, .kittyImage)
        XCTAssertEqual(TerminalMetalRenderPass.kittyImage.rawValue, 4)
    }

    func testCellRectIsInDrawablePixels() {
        let rect = TerminalMetalBackgroundInstance.cellRect(column: 2, row: 4, cellWidth: 12, cellHeight: 20)
        XCTAssertEqual(rect, SIMD4<Float>(24, 80, 12, 20))
    }

    func testViewportCapturesScale() {
        let viewport = TerminalMetalViewport(drawableSize: .init(width: 128, height: 64), backingScale: 2)
        XCTAssertEqual(viewport.drawableWidth, 128)
        XCTAssertEqual(viewport.drawableHeight, 64)
        XCTAssertEqual(viewport.backingScale, 2)
        XCTAssertEqual(viewport._pad, 0)
        XCTAssertEqual(viewport.drawablePixelSize, SIMD2<Float>(128, 64))
        XCTAssertEqual(viewport.logicalPointSize, SIMD2<Float>(64, 32))
    }

    func testGlyphColorIsPremultipliedBeforeUpload() {
        let source = SIMD4<Float>(0.5, 0.25, 0.75, 0.5)
        let premul = TerminalMetalGlyphInstance.premultipliedColor(source)
        XCTAssertEqual(premul, SIMD4<Float>(0.25, 0.125, 0.375, 0.5))
    }
}
