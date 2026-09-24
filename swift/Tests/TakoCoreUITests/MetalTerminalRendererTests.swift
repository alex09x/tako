import CoreGraphics
import CoreText
import Foundation
import Metal
import XCTest
import simd
@testable import TakoCoreUI

/// The CPU half of `MetalTerminalRenderer` -- validation, colors, selection
/// bounds, pass ordering, placement geometry and buffer growth -- is testable
/// with no GPU at all. The two tests at the bottom stand a real device up and
/// compile the shipped shaders, and skip themselves when there is no device.
final class MetalTerminalRendererTests: XCTestCase {

    // MARK: - Fixtures

    /// One packed cell, in the layout `viewport_packed` writes.
    private struct CellSpec {
        var ch: UInt32 = 32
        var fg: (r: UInt8, g: UInt8, b: UInt8) = (0xed, 0xe6, 0xdf)
        var bg: (r: UInt8, g: UInt8, b: UInt8) = (0x14, 0x10, 0x0e)
        var bits: UInt16 = 0
        var underlineStyle: UInt8 = 0
        var underlineColor: (r: UInt8, g: UInt8, b: UInt8) = (0xed, 0xe6, 0xdf)

        static let boldBit: UInt16 = 1 << 0
        static let dimBit: UInt16 = 1 << 1
        static let italicBit: UInt16 = 1 << 2
        static let underlineBit: UInt16 = 1 << 3
        static let reverseBit: UInt16 = 1 << 5
        static let hiddenBit: UInt16 = 1 << 6
        static let strikethroughBit: UInt16 = 1 << 7
        static let overlineBit: UInt16 = 1 << 8
        static let wideBit: UInt16 = 1 << 9
    }

    private func packed(_ cells: [CellSpec]) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(cells.count * TerminalCell.byteSize)
        for cell in cells {
            bytes.append(UInt8(truncatingIfNeeded: cell.ch))
            bytes.append(UInt8(truncatingIfNeeded: cell.ch >> 8))
            bytes.append(UInt8(truncatingIfNeeded: cell.ch >> 16))
            bytes.append(UInt8(truncatingIfNeeded: cell.ch >> 24))
            bytes.append(contentsOf: [cell.fg.r, cell.fg.g, cell.fg.b])
            bytes.append(contentsOf: [cell.bg.r, cell.bg.g, cell.bg.b])
            bytes.append(UInt8(truncatingIfNeeded: cell.bits))
            bytes.append(UInt8(truncatingIfNeeded: cell.bits >> 8))
            bytes.append(cell.underlineStyle)
            bytes.append(contentsOf: [cell.underlineColor.r, cell.underlineColor.g, cell.underlineColor.b])
        }
        return Data(bytes)
    }

    private func snapshot(
        cols: UInt32,
        rows: UInt32,
        cursorVisible: Bool = false,
        cursorRow: UInt32 = 0,
        cursorCol: UInt32 = 0,
        cursorShape: FfiCursorShape = .block,
        blinking: Bool = false,
        selection: FfiSelectionRange? = nil,
        placements: [FfiGraphicsPlacement] = [],
        viewportOffset: UInt32 = 0,
        alternateScreen: Bool = false,
        damagedRows: [UInt32]? = nil
    ) -> FfiSnapshot {
        FfiSnapshot(
            cols: cols,
            rows: rows,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            cursorVisible: cursorVisible,
            cursorStyle: FfiCursorStyle(shape: cursorShape, blinking: blinking),
            title: "test",
            modes: FfiTerminalModes(
                autowrap: true,
                originMode: false,
                cursorKeyAppMode: false,
                mouseTracking: .off,
                mouseUtf8: false,
                mouseSgr: false,
                focusEvents: false,
                bracketedPaste: false,
                alternateScreen: alternateScreen,
                alternateScroll: false
            ),
            viewportOffset: viewportOffset,
            scrollbackLen: 0,
            damagedRows: damagedRows ?? Array(0..<rows),
            selection: selection,
            graphicsPlacements: placements
        )
    }

    private func frame(
        cols: UInt32,
        rows: UInt32,
        cells: [CellSpec]? = nil,
        packedOverride: Data? = nil,
        cursorVisible: Bool = false,
        cursorRow: UInt32 = 0,
        cursorCol: UInt32 = 0,
        cursorShape: FfiCursorShape = .block,
        blinking: Bool = false,
        selection: FfiSelectionRange? = nil,
        placements: [FfiGraphicsPlacement] = [],
        viewportOffset: UInt32 = 0,
        alternateScreen: Bool = false,
        damagedRows: [UInt32]? = nil
    ) -> FfiRenderFrame {
        let filled = cells ?? Array(repeating: CellSpec(), count: Int(cols) * Int(rows))
        return FfiRenderFrame(
            snapshot: snapshot(
                cols: cols,
                rows: rows,
                cursorVisible: cursorVisible,
                cursorRow: cursorRow,
                cursorCol: cursorCol,
                cursorShape: cursorShape,
                blinking: blinking,
                selection: selection,
                placements: placements,
                viewportOffset: viewportOffset,
                alternateScreen: alternateScreen,
                damagedRows: damagedRows
            ),
            packedCells: packedOverride ?? packed(filled),
            epoch: 0
        )
    }

    /// Fixed metrics so every geometry assertion is exact: 10x20 pixel cells,
    /// baseline 15 pixels down, no backing scale.
    private func metrics(scale: CGFloat = 1) -> TerminalMetalCellMetrics {
        TerminalMetalCellMetrics(
            font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
            cellWidth: 10,
            cellHeight: 20,
            ascent: 15,
            scale: scale
        )
    }

    private func planner(scale: CGFloat = 1) -> TerminalMetalFramePlanner {
        TerminalMetalFramePlanner(metrics: metrics(scale: scale))
    }

    private let viewport = TerminalMetalViewport(drawableWidth: 200, drawableHeight: 200)

    // MARK: - Validation

    func testValidationAcceptsWellFormedFrame() {
        let frame = frame(cols: 4, rows: 3)
        XCTAssertEqual(TerminalMetalFramePlanner.validate(frame: frame, viewport: viewport), .valid)
    }

    func testValidationRejectsTruncatedPackedCells() {
        let short = frame(cols: 4, rows: 3, packedOverride: packed(Array(repeating: CellSpec(), count: 5)))
        XCTAssertEqual(
            TerminalMetalFramePlanner.validate(frame: short, viewport: viewport),
            .truncatedPackedCells(expected: 4 * 3 * TerminalCell.byteSize, actual: 5 * TerminalCell.byteSize)
        )
    }

    func testValidationReportsEmptyGrid() {
        let empty = frame(cols: 0, rows: 0, packedOverride: Data())
        XCTAssertEqual(TerminalMetalFramePlanner.validate(frame: empty, viewport: viewport), .emptyGrid)
    }

    func testValidationRejectsAbsurdGridDimensions() {
        let huge = FfiRenderFrame(
            snapshot: snapshot(cols: 4_000_000, rows: 4_000_000), packedCells: Data(), epoch: 0)
        XCTAssertEqual(
            TerminalMetalFramePlanner.validate(frame: huge, viewport: viewport),
            .invalidGridDimensions
        )
    }

    func testValidationRejectsUnusableViewport() {
        let frame = frame(cols: 2, rows: 2)
        let zero = TerminalMetalViewport(drawableWidth: 0, drawableHeight: 0)
        XCTAssertEqual(TerminalMetalFramePlanner.validate(frame: frame, viewport: zero), .invalidViewport)
        let nan = TerminalMetalViewport(drawableWidth: .nan, drawableHeight: 100)
        XCTAssertEqual(TerminalMetalFramePlanner.validate(frame: frame, viewport: nan), .invalidViewport)
    }

    func testMalformedFrameIsSkippedWholeWithoutInstances() {
        let planner = planner()
        let short = frame(cols: 8, rows: 8, packedOverride: Data([1, 2, 3]))
        let stats = planner.plan(frame: short, viewport: viewport)

        XCTAssertFalse(stats.isRenderable)
        XCTAssertEqual(stats.totalInstances, 0)
        XCTAssertEqual(planner.activePasses, [])
        XCTAssertEqual(stats.visitedCells, 0)
    }

    func testEmptyFramePlansNothing() {
        let planner = planner()
        let stats = planner.plan(frame: frame(cols: 0, rows: 0, packedOverride: Data()), viewport: viewport)

        XCTAssertEqual(stats.validation, .emptyGrid)
        XCTAssertEqual(stats.totalInstances, 0)
        XCTAssertTrue(planner.backgroundInstances.isEmpty)
        XCTAssertTrue(planner.glyphInstances.isEmpty)
    }

    // MARK: - Colors and backgrounds

    func testCellBackgroundsUseDrawablePixelGeometryAndSkipTheDefault() {
        let planner = planner()
        var cells = Array(repeating: CellSpec(), count: 4)
        cells[3].bg = (0, 0, 255)
        let stats = planner.plan(frame: frame(cols: 2, rows: 2, cells: cells), viewport: viewport)

        XCTAssertTrue(stats.isRenderable)
        XCTAssertEqual(stats.visitedCells, 4)
        // Three cells keep the palette background, which the pass clears to.
        XCTAssertEqual(planner.backgroundInstances.count, 1)
        let instance = planner.backgroundInstances[0]
        XCTAssertEqual(instance.rect, SIMD4<Float>(10, 20, 10, 20))
        XCTAssertEqual(instance.color, SIMD4<Float>(0, 0, 1, 1))
    }

    func testAdjacentEqualBackgroundsMergeIntoOneInstance() {
        let planner = planner()
        var cells = Array(repeating: CellSpec(), count: 8)
        for index in 0..<4 { cells[index].bg = (255, 0, 0) }
        let stats = planner.plan(frame: frame(cols: 4, rows: 2, cells: cells), viewport: viewport)

        XCTAssertEqual(stats.backgroundInstances, 1)
        XCTAssertEqual(planner.backgroundInstances[0].rect, SIMD4<Float>(0, 0, 40, 20))
    }

    func testBackgroundRunsDoNotSpanRows() {
        let planner = planner()
        var cells = Array(repeating: CellSpec(), count: 4)
        for index in 0..<4 { cells[index].bg = (0, 255, 0) }
        planner.plan(frame: frame(cols: 2, rows: 2, cells: cells), viewport: viewport)

        XCTAssertEqual(planner.backgroundInstances.count, 2)
        XCTAssertEqual(planner.backgroundInstances[0].rect, SIMD4<Float>(0, 0, 20, 20))
        XCTAssertEqual(planner.backgroundInstances[1].rect, SIMD4<Float>(0, 20, 20, 20))
    }

    func testReverseVideoSwapsForegroundAndBackground() {
        let planner = planner()
        var cell = CellSpec()
        cell.ch = 65
        cell.fg = (255, 0, 0)
        cell.bg = (0, 0, 255)
        cell.bits = CellSpec.reverseBit
        planner.plan(frame: frame(cols: 1, rows: 1, cells: [cell]), viewport: viewport)

        XCTAssertEqual(planner.backgroundInstances.count, 1)
        XCTAssertEqual(planner.backgroundInstances[0].color, SIMD4<Float>(1, 0, 0, 1))
        XCTAssertEqual(planner.glyphInstances.count, 1)
        XCTAssertEqual(planner.glyphInstances[0].color, SIMD4<Float>(0, 0, 1, 1))
    }

    func testLinearEncodingLinearizesComponentsAndPremultipliesGlyphColor() {
        XCTAssertEqual(TerminalMetalColor.component(255, encoding: .displayEncoded), 1)
        XCTAssertEqual(TerminalMetalColor.component(0, encoding: .linear), 0)
        XCTAssertEqual(TerminalMetalColor.component(255, encoding: .linear), 1, accuracy: 1e-5)
        // sRGB 128 is roughly 21.6% of the way up in linear light.
        XCTAssertEqual(TerminalMetalColor.component(128, encoding: .linear), 0.2158, accuracy: 1e-3)

        let premultiplied = TerminalMetalColor.premultiplied(SIMD4<Float>(1, 0.5, 0.25, 0.5))
        XCTAssertEqual(premultiplied, SIMD4<Float>(0.5, 0.25, 0.125, 0.5))
    }

    func testDimAndUnfocusedTextFadeThroughPremultipliedAlpha() {
        let planner = planner()
        planner.isFocused = false
        var cell = CellSpec()
        cell.ch = 65
        cell.fg = (255, 255, 255)
        cell.bits = CellSpec.dimBit
        planner.plan(frame: frame(cols: 1, rows: 1, cells: [cell]), viewport: viewport)

        XCTAssertEqual(planner.glyphInstances.count, 1)
        let expected = planner.palette.dimAlpha * planner.palette.unfocusedTextAlpha
        XCTAssertEqual(planner.glyphInstances[0].color.w, expected, accuracy: 1e-5)
        XCTAssertEqual(planner.glyphInstances[0].color.x, expected, accuracy: 1e-5)
    }

    func testMinimumContrastDisplayP3AndZeroAlphaAreDeterministic() {
        let same = SIMD4<Float>(0.5, 0.5, 0.5, 1)
        let adjusted = TerminalMetalColor.enforcingMinimumContrast(
            foreground: same,
            background: same,
            ratio: 7,
            encoding: .displayEncoded
        )
        XCTAssertNotEqual(adjusted.x, same.x)
        XCTAssertEqual(TerminalMetalColor.premultiplied(SIMD4<Float>(.nan, .infinity, 1, 0)), .zero)

        let srgb = TerminalMetalColor.rgba(r: 255, g: 0, b: 0, encoding: .linear, colorSpace: .sRGB)
        let p3 = TerminalMetalColor.rgba(r: 255, g: 0, b: 0, encoding: .linear, colorSpace: .displayP3)
        XCTAssertEqual(srgb, SIMD4<Float>(1, 0, 0, 1))
        XCTAssertLessThan(p3.x, srgb.x)
        XCTAssertGreaterThan(p3.y, 0)
        XCTAssertGreaterThan(p3.z, 0)
    }

    // MARK: - Selection

    private func selection(
        _ startRow: UInt32,
        _ startCol: UInt32,
        _ endRow: UInt32,
        _ endCol: UInt32,
        _ mode: FfiSelectionMode
    ) -> FfiSelectionRange {
        FfiSelectionRange(startRow: startRow, startCol: startCol, endRow: endRow, endCol: endCol, mode: mode)
    }

    func testLinearSelectionCoversPartialEndsAndFullMiddleRows() {
        let spans = TerminalMetalFramePlanner.selectionSpans(
            for: selection(0, 3, 2, 4, .linear),
            cols: 10,
            rows: 5
        )
        XCTAssertEqual(spans, [
            TerminalMetalSelectionSpan(row: 0, firstColumn: 3, lastColumn: 9),
            TerminalMetalSelectionSpan(row: 1, firstColumn: 0, lastColumn: 9),
            TerminalMetalSelectionSpan(row: 2, firstColumn: 0, lastColumn: 4),
        ])
    }

    func testRectangularSelectionCoversColumnBoxOnly() {
        let spans = TerminalMetalFramePlanner.selectionSpans(
            for: selection(1, 6, 3, 2, .rectangular),
            cols: 10,
            rows: 5
        )
        XCTAssertEqual(spans, [
            TerminalMetalSelectionSpan(row: 1, firstColumn: 2, lastColumn: 6),
            TerminalMetalSelectionSpan(row: 2, firstColumn: 2, lastColumn: 6),
            TerminalMetalSelectionSpan(row: 3, firstColumn: 2, lastColumn: 6),
        ])
    }

    func testSelectionBoundsNormalizeReversedRangesAndClampToGrid() {
        let reversed = TerminalMetalFramePlanner.selectionSpans(
            for: selection(2, 4, 0, 3, .linear),
            cols: 10,
            rows: 5
        )
        XCTAssertEqual(reversed.first, TerminalMetalSelectionSpan(row: 0, firstColumn: 3, lastColumn: 9))
        XCTAssertEqual(reversed.last, TerminalMetalSelectionSpan(row: 2, firstColumn: 0, lastColumn: 4))

        // A range that outruns the grid is clipped, not trusted.
        let clamped = TerminalMetalFramePlanner.selectionSpans(
            for: selection(0, 0, 99, 99, .linear),
            cols: 4,
            rows: 2
        )
        XCTAssertEqual(clamped, [
            TerminalMetalSelectionSpan(row: 0, firstColumn: 0, lastColumn: 3),
            TerminalMetalSelectionSpan(row: 1, firstColumn: 0, lastColumn: 3),
        ])
        XCTAssertEqual(TerminalMetalFramePlanner.selectionSpans(for: selection(0, 0, 0, 0, .linear), cols: 0, rows: 0), [])
    }

    func testSelectionInstancesAreDrawablePixelRects() {
        let planner = planner()
        let stats = planner.plan(
            frame: frame(cols: 4, rows: 2, selection: selection(0, 1, 1, 2, .linear)),
            viewport: viewport
        )

        XCTAssertEqual(stats.selectionInstances, 2)
        XCTAssertEqual(planner.selectionInstances[0].rect, SIMD4<Float>(10, 0, 30, 20))
        XCTAssertEqual(planner.selectionInstances[1].rect, SIMD4<Float>(0, 20, 30, 20))
        // The overlay is translucent, and reaches the GPU premultiplied.
        let color = planner.selectionInstances[0].color
        XCTAssertEqual(color.w, planner.palette.selection.w, accuracy: 1e-5)
        XCTAssertEqual(color.x, planner.palette.selection.x * planner.palette.selection.w, accuracy: 1e-5)
    }

    // MARK: - Ordering

    func testPassOrderDrawsBackgroundSelectionImagesGlyphsThenCursor() {
        XCTAssertEqual(MetalTerminalRenderer.passOrder, [
            .background,
            .selection,
            .kittyImage,
            .cursor,
            .grayscaleGlyph,
            .colorGlyph,
            .decoration,
        ])
        XCTAssertEqual(TerminalMetalRenderPass.orderedWithImages, MetalTerminalRenderer.passOrder)
    }

    func testActivePassesFollowDrawOrderWithGlyphsBeforeCursor() {
        let planner = planner()
        var cells = Array(repeating: CellSpec(), count: 4)
        cells[0].ch = 65
        cells[0].bg = (10, 20, 30)
        let stored = FfiStoredImage(format: .rgb, width: 2, height: 2, pixels: Data(repeating: 0x40, count: 12))
        planner.plan(
            frame: frame(
                cols: 2,
                rows: 2,
                cells: cells,
                cursorVisible: true,
                selection: selection(0, 0, 0, 1, .linear),
                placements: [FfiGraphicsPlacement(imageId: 7, placementId: 1, row: 1, col: 1)]
            ),
            viewport: viewport,
            imageProvider: { $0 == 7 ? stored : nil }
        )

        XCTAssertEqual(planner.activePasses, [.background, .selection, .kittyImage, .cursor, .grayscaleGlyph])
    }

    // MARK: - Glyphs

    func testGlyphsRasterizeThroughTheAtlasAndMarkPagesDirty() {
        let planner = planner()
        var cell = CellSpec()
        cell.ch = 65 // "A"
        let stats = planner.plan(frame: frame(cols: 1, rows: 1, cells: [cell]), viewport: viewport)

        XCTAssertEqual(stats.glyphInstances, 1)
        XCTAssertEqual(stats.atlasPageCount, 1)
        XCTAssertEqual(planner.atlasGeneration, 1)
        XCTAssertEqual(planner.dirtyAtlasPages, [0])
        XCTAssertEqual(planner.glyphPageRanges.count, 1)
        XCTAssertEqual(planner.glyphPageRanges[0].range, 0..<1)

        let instance = planner.glyphInstances[0]
        XCTAssertGreaterThan(instance.destRect.z, 0)
        XCTAssertGreaterThan(instance.destRect.w, 0)
        // The mask sits inside its cell, above the baseline at y = 15.
        XCTAssertGreaterThanOrEqual(instance.destRect.x, 0)
        XCTAssertLessThanOrEqual(instance.destRect.y + instance.destRect.w, 16)
        XCTAssertLessThanOrEqual(instance.uvRect.z, 1)
        XCTAssertLessThanOrEqual(instance.uvRect.w, 1)
    }

    func testRepeatedGlyphsReuseTheAtlasWithoutANewGeneration() {
        let planner = planner()
        var cell = CellSpec()
        cell.ch = 65
        planner.plan(frame: frame(cols: 1, rows: 1, cells: [cell]), viewport: viewport)
        let generation = planner.atlasGeneration
        planner.clearDirtyAtlasPages()

        let stats = planner.plan(frame: frame(cols: 1, rows: 1, cells: [cell]), viewport: viewport)

        XCTAssertEqual(stats.glyphInstances, 1)
        XCTAssertEqual(planner.atlasGeneration, generation)
        XCTAssertTrue(planner.dirtyAtlasPages.isEmpty, "an unchanged atlas must not schedule an upload")
        XCTAssertEqual(planner.atlas.cachedCount, 1)
    }

    func testBlankHiddenAndWideTailCellsProduceNoGlyphs() {
        let planner = planner()
        var hidden = CellSpec()
        hidden.ch = 65
        hidden.bits = CellSpec.hiddenBit
        let blank = CellSpec()          // space
        let wideTail = CellSpec(ch: 0)  // tail of a double-width pair
        let stats = planner.plan(
            frame: frame(cols: 3, rows: 1, cells: [hidden, blank, wideTail]),
            viewport: viewport
        )

        XCTAssertEqual(stats.glyphInstances, 0)
        XCTAssertEqual(stats.skippedGlyphs, 3)
        XCTAssertEqual(stats.visitedCells, 3)
    }

    func testStyledFallbackAndWideGlyphPlanning() throws {
        let planner = planner()
        let baseName = CTFontCopyPostScriptName(planner.metrics.font) as String
        let fallback = try XCTUnwrap(planner.resolvedFontName(for: 0x1F600, bold: true, italic: true))
        XCTAssertNotEqual(fallback, baseName)

        var wide = CellSpec(ch: 0x4E2D)
        wide.bits = CellSpec.boldBit | CellSpec.italicBit | CellSpec.wideBit
        planner.plan(frame: frame(cols: 2, rows: 1, cells: [wide, CellSpec(ch: 0)]), viewport: viewport)
        let instance = try XCTUnwrap((planner.glyphInstances + planner.colorGlyphInstances).first)
        XCTAssertNotEqual(instance.flags & (1 << 0), 0)
        XCTAssertNotEqual(instance.flags & (1 << 1), 0)
        XCTAssertNotEqual(instance.flags & (1 << 2), 0)
        XCTAssertGreaterThanOrEqual(instance.destRect.x, 0)
        XCTAssertLessThanOrEqual(instance.destRect.x + instance.destRect.z, 20)
    }

    func testColorEmojiPlansASeparateColorGlyphPass() {
        let planner = planner()
        var emoji = CellSpec()
        emoji.ch = 0x1F600
        let stats = planner.plan(frame: frame(cols: 1, rows: 1, cells: [emoji]), viewport: viewport)
        XCTAssertEqual(stats.colorGlyphInstances, 1)
        XCTAssertTrue(planner.glyphInstances.isEmpty)
        XCTAssertEqual(planner.colorGlyphInstances[0].flags & TerminalMetalGlyphInstance.colorGlyphFlag,
                       TerminalMetalGlyphInstance.colorGlyphFlag)
        XCTAssertEqual(planner.atlas.pages[0].pixelFormat, .bgra8Premultiplied)
    }

    func testEveryDecorationTypeAndWideSpanIsPlannedOnGPU() {
        var cells: [CellSpec] = (1...5).map { style in
            var cell = CellSpec()
            cell.bits = CellSpec.underlineBit
            cell.underlineStyle = UInt8(style)
            cell.underlineColor = (255, 64, 32)
            return cell
        }
        var strike = CellSpec()
        strike.bits = CellSpec.strikethroughBit
        var overline = CellSpec()
        overline.bits = CellSpec.overlineBit | CellSpec.wideBit
        cells += [strike, overline, CellSpec(ch: 0)]

        let planner = planner()
        let stats = planner.plan(frame: frame(cols: 8, rows: 1, cells: cells), viewport: viewport)
        XCTAssertEqual(stats.decorationInstances, 7)
        XCTAssertEqual(planner.decorationInstances.map(\.style), TerminalMetalDecorationStyle.allCases.map(\.rawValue))
        XCTAssertEqual(planner.decorationInstances.last?.rect.z, 20)
    }

    // MARK: - Cursor

    func testVisibleCursorIsOneBlockQuadOverTheCell() {
        let planner = planner()
        let stats = planner.plan(
            frame: frame(cols: 4, rows: 4, cursorVisible: true, cursorRow: 2, cursorCol: 1),
            viewport: viewport
        )

        XCTAssertEqual(stats.cursorInstances, 1)
        let cursor = planner.cursorInstances[0]
        XCTAssertEqual(cursor.rect, SIMD4<Float>(10, 40, 10, 20))
        XCTAssertEqual(cursor.shape, TerminalMetalCursorShape.block.rawValue)
        XCTAssertEqual(cursor.blinkState, 0)
    }

    func testBlockCursorDrawsBelowContrastingGlyphWhileThinCursorsKeepText() {
        let planner = TerminalMetalFramePlanner(metrics: metrics(), minimumContrast: 4.5)
        var cell = CellSpec()
        cell.ch = 65
        cell.fg = (0xf4, 0x58, 0x1c)
        planner.plan(
            frame: frame(cols: 1, rows: 1, cells: [cell], cursorVisible: true, cursorShape: .block),
            viewport: viewport
        )
        XCTAssertEqual(planner.activePasses, [.cursor, .grayscaleGlyph])
        XCTAssertNotEqual(planner.glyphInstances[0].color, TerminalMetalColor.premultiplied(planner.palette.cursor))

        planner.plan(
            frame: frame(cols: 1, rows: 1, cells: [cell], cursorVisible: true, cursorShape: .bar),
            viewport: viewport
        )
        XCTAssertEqual(planner.cursorInstances[0].rect.z, 2)
        XCTAssertEqual(planner.glyphInstances.count, 1)
    }

    func testHiddenBlinkedOffAndOutOfRangeCursorsAreOmitted() {
        let planner = planner()
        XCTAssertEqual(planner.plan(frame: frame(cols: 4, rows: 4), viewport: viewport).cursorInstances, 0)

        planner.cursorBlinkPhaseOn = false
        let blinked = frame(cols: 4, rows: 4, cursorVisible: true, blinking: true)
        XCTAssertEqual(planner.plan(frame: blinked, viewport: viewport).cursorInstances, 0)

        planner.cursorBlinkPhaseOn = true
        XCTAssertEqual(planner.plan(frame: blinked, viewport: viewport).cursorInstances, 1)

        let offGrid = frame(cols: 4, rows: 4, cursorVisible: true, cursorRow: 99, cursorCol: 99)
        XCTAssertEqual(planner.plan(frame: offGrid, viewport: viewport).cursorInstances, 0)
    }

    func testCursorIsHiddenInScrollbackAndUnfocusedBlinkRemainsVisible() {
        let planner = planner()
        planner.cursorBlinkPhaseOn = false
        let blinking = frame(cols: 4, rows: 4, cursorVisible: true, blinking: true)
        XCTAssertEqual(planner.plan(frame: blinking, viewport: viewport).cursorInstances, 0)

        planner.isFocused = false
        XCTAssertEqual(planner.plan(frame: blinking, viewport: viewport).cursorInstances, 4)

        let scrollback = frame(
            cols: 4,
            rows: 4,
            cursorVisible: true,
            blinking: false,
            viewportOffset: 1
        )
        XCTAssertEqual(planner.plan(frame: scrollback, viewport: viewport).cursorInstances, 0)
    }

    func testBarAndUnderlineCursorsUseThinRectsAndUnfocusedDrawsAnOutline() {
        let planner = planner()
        planner.plan(
            frame: frame(cols: 2, rows: 2, cursorVisible: true, cursorShape: .bar),
            viewport: viewport
        )
        XCTAssertEqual(planner.cursorInstances[0].rect, SIMD4<Float>(0, 0, 2, 20))

        planner.plan(
            frame: frame(cols: 2, rows: 2, cursorVisible: true, cursorShape: .underline),
            viewport: viewport
        )
        XCTAssertEqual(planner.cursorInstances[0].rect, SIMD4<Float>(0, 18, 10, 2))

        planner.isFocused = false
        let stats = planner.plan(frame: frame(cols: 2, rows: 2, cursorVisible: true), viewport: viewport)
        XCTAssertEqual(stats.cursorInstances, 4, "an unfocused block cursor is four edge quads")
        XCTAssertTrue(planner.cursorInstances.allSatisfy {
            $0.shape == TerminalMetalCursorShape.hollowBlock.rawValue
        })
    }

    // MARK: - Kitty graphics

    func testPlacementGeometryAnchorsTheImageAtTheCellTopLeft() {
        let planner = planner()
        let stored = FfiStoredImage(format: .rgb, width: 24, height: 36, pixels: Data(repeating: 0x7f, count: 24 * 36 * 3))
        let stats = planner.plan(
            frame: frame(
                cols: 8,
                rows: 8,
                placements: [FfiGraphicsPlacement(imageId: 42, placementId: 1, row: 2, col: 3)]
            ),
            viewport: viewport,
            imageProvider: { $0 == 42 ? stored : nil }
        )

        XCTAssertEqual(stats.imageInstances, 1)
        XCTAssertEqual(stats.skippedPlacements, 0)
        let instance = planner.imageInstances[0]
        XCTAssertEqual(instance.destRect, SIMD4<Float>(30, 40, 24, 36))
        XCTAssertEqual(instance.uvRect, SIMD4<Float>(0, 0, 1, 1))
        XCTAssertEqual(instance.tint, SIMD4<Float>(1, 1, 1, 1))
        XCTAssertEqual(instance.imageId, 42)
    }

    func testMetadataProviderPlansImageWithoutFetchingStoredBytes() {
        let planner = planner()
        var byteFetches = 0
        var metadataFetches = 0
        let metadata = FfiGraphicsImageMetadata(format: .rgb, width: 24, height: 36, generation: 7)
        let stats = planner.plan(
            frame: frame(
                cols: 8,
                rows: 8,
                placements: [
                    FfiGraphicsPlacement(imageId: 42, placementId: 1, row: 2, col: 3),
                    FfiGraphicsPlacement(imageId: 42, placementId: 2, row: 4, col: 1),
                ]
            ),
            viewport: viewport,
            imageProvider: { _ in byteFetches += 1; return nil },
            imageMetadataProvider: { _ in metadataFetches += 1; return metadata }
        )

        XCTAssertEqual(stats.imageInstances, 2)
        XCTAssertEqual(byteFetches, 0)
        XCTAssertEqual(metadataFetches, 1, "one metadata lookup serves every placement of an image")
        XCTAssertEqual(planner.imageInstances[0].destRect, SIMD4<Float>(30, 40, 24, 36))
    }

    func testLegacyImageProviderRemainsPlanningFallback() {
        let planner = planner()
        var byteFetches = 0
        let stored = FfiStoredImage(format: .rgb, width: 24, height: 36, pixels: Data(repeating: 0x7f, count: 24 * 36 * 3))
        let stats = planner.plan(
            frame: frame(
                cols: 8,
                rows: 8,
                placements: [FfiGraphicsPlacement(imageId: 42, placementId: 1, row: 2, col: 3)]
            ),
            viewport: viewport,
            imageProvider: { _ in byteFetches += 1; return stored }
        )

        XCTAssertEqual(stats.imageInstances, 1)
        XCTAssertEqual(byteFetches, 1)
    }

    func testMalformedAndOffGridPlacementsAreSkippedSafely() {
        let planner = planner()
        let zeroSized = FfiStoredImage(format: .rgba, width: 0, height: 4, pixels: Data())
        let stats = planner.plan(
            frame: frame(
                cols: 4,
                rows: 4,
                placements: [
                    FfiGraphicsPlacement(imageId: 1, placementId: 1, row: 0, col: 0),   // no image
                    FfiGraphicsPlacement(imageId: 2, placementId: 2, row: 0, col: 0),   // zero-sized
                    FfiGraphicsPlacement(imageId: 3, placementId: 3, row: 99, col: 0),  // off grid
                ]
            ),
            viewport: viewport,
            imageProvider: { $0 == 2 ? zeroSized : nil }
        )

        XCTAssertEqual(stats.imageInstances, 0)
        XCTAssertEqual(stats.skippedPlacements, 3)
        XCTAssertTrue(stats.isRenderable, "bad images do not invalidate the frame")
    }

    // MARK: - Buffers

    func testBufferSizingReusesUntilTheFrameOutgrowsTheBuffer() {
        // Nothing to upload: no allocation.
        XCTAssertNil(TerminalMetalBufferSizing.growth(existingLength: 0, requiredLength: 0))
        // First upload takes the minimum, not the exact size.
        XCTAssertEqual(TerminalMetalBufferSizing.growth(existingLength: 0, requiredLength: 96), 4096)
        // A steady-state frame reuses what it has.
        XCTAssertNil(TerminalMetalBufferSizing.growth(existingLength: 4096, requiredLength: 4096))
        XCTAssertNil(TerminalMetalBufferSizing.growth(existingLength: 8192, requiredLength: 100))
        // Growth doubles rather than tracking each frame's exact size.
        XCTAssertEqual(TerminalMetalBufferSizing.growth(existingLength: 4096, requiredLength: 4097), 8192)
        XCTAssertEqual(TerminalMetalBufferSizing.growth(existingLength: 4096, requiredLength: 20000), 32768)
        // Absurd requests fall back to the exact length instead of overflowing.
        XCTAssertEqual(
            TerminalMetalBufferSizing.growth(existingLength: 0, requiredLength: Int.max),
            Int.max
        )
    }

    func testFramesInFlightIsTripleBuffered() {
        XCTAssertEqual(MetalTerminalRenderer.framesInFlight, 3)
    }

    // MARK: - GPU

    /// Compiles the shipped shader source so the pipelines are built against
    /// the same functions and struct layouts the app ships.
    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../Tests/TakoCoreUITests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // .../swift
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let source = try String(contentsOf: url, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
    }

    func testRendererBuildsEveryPipelineFromTheShippedShaders() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )

        XCTAssertEqual(renderer.statistics.totalInstances, 0)
        XCTAssertEqual(renderer.bufferAllocationCount, 0, "buffers are allocated on first use, not up front")
        XCTAssertEqual(renderer.clearColor.alpha, 1, accuracy: 1e-6)
    }

    func testConfigureLayerPublishesTheRenderersOutputColorSpace() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics(),
            colorSpace: .displayP3
        )
        let layer = CAMetalLayer()

        renderer.configure(layer: layer)

        XCTAssertTrue(layer.device === device)
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.displayP3)
    }

    func testAtlasTextureUploadsCopyOnWriteOnlyWhenPageGenerationChanges() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 10, height: 20, mipmapped: false
        )
        textureDescriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))

        func render(_ scalar: UInt32) {
            var cell = CellSpec()
            cell.ch = scalar
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            _ = renderer.render(
                frame: frame(cols: 1, rows: 1, cells: [cell]),
                viewport: TerminalMetalViewport(drawableWidth: 10, drawableHeight: 20),
                descriptor: pass,
                waitUntilCompleted: true
            )
        }

        render(65)
        XCTAssertEqual(renderer.atlasUploadCount, 1)
        let original = try XCTUnwrap(renderer.atlasTexturesForTesting.first ?? nil)
        render(65)
        XCTAssertEqual(renderer.atlasUploadCount, 1)
        let reused = try XCTUnwrap(renderer.atlasTexturesForTesting.first ?? nil)
        XCTAssertEqual(ObjectIdentifier(original as AnyObject), ObjectIdentifier(reused as AnyObject))
        render(66)
        XCTAssertEqual(renderer.atlasUploadCount, 2)
        let replacement = try XCTUnwrap(renderer.atlasTexturesForTesting.first ?? nil)
        XCTAssertNotEqual(ObjectIdentifier(original as AnyObject), ObjectIdentifier(replacement as AnyObject))
    }

    func testImageMetadataGatesByteFetchesAcrossGenerationsAndRecreation() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        var metadata = FfiGraphicsImageMetadata(format: .rgb, width: 2, height: 2, generation: 1)
        let stored = FfiStoredImage(format: .rgb, width: 2, height: 2, pixels: Data(repeating: 0x40, count: 12))
        var byteFetches = 0
        var metadataFetches = 0
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics(),
            imageProvider: { _ in byteFetches += 1; return stored },
            imageMetadataProvider: { _ in metadataFetches += 1; return metadata }
        )
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 10, height: 20, mipmapped: false
        )
        textureDescriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let placement = FfiGraphicsPlacement(imageId: 7, placementId: 1, row: 0, col: 0)

        func render(_ placements: [FfiGraphicsPlacement]) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            _ = renderer.render(
                frame: frame(cols: 1, rows: 1, placements: placements),
                viewport: TerminalMetalViewport(drawableWidth: 10, drawableHeight: 20),
                descriptor: pass,
                waitUntilCompleted: true
            )
        }

        render([placement])
        XCTAssertEqual(byteFetches, 1)
        XCTAssertEqual(metadataFetches, 1)
        render([placement])
        XCTAssertEqual(byteFetches, 1, "stable generation must not re-fetch bytes")
        XCTAssertEqual(metadataFetches, 2, "metadata crosses FFI once per live id and frame")

        metadata.generation = 2
        render([placement])
        XCTAssertEqual(byteFetches, 2, "a changed generation must refresh the same id")
        XCTAssertEqual(metadataFetches, 3)

        render([])
        metadata.generation = 3
        render([placement])
        XCTAssertEqual(byteFetches, 3, "a purged id must fetch when recreated")
        XCTAssertEqual(metadataFetches, 4)
    }

    func testOffscreenRenderDrawsCellBackgroundsAndReusesBuffers() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        try XCTSkipUnless(device.hasUnifiedMemory, "readback path needs shared storage")
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 20,
            height: 40,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        var cells = Array(repeating: CellSpec(), count: 4)
        cells[0].bg = (0, 0, 255)
        let renderFrame = frame(cols: 2, rows: 2, cells: cells, cursorVisible: true, cursorRow: 1, cursorCol: 1)
        let renderViewport = TerminalMetalViewport(drawableWidth: 20, drawableHeight: 40)

        func renderOnce() -> TerminalMetalFrameStatistics {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = renderer.clearColor
            return renderer.render(
                frame: renderFrame,
                viewport: renderViewport,
                descriptor: pass,
                drawable: nil,
                waitUntilCompleted: true
            )
        }

        let stats = renderOnce()
        XCTAssertTrue(stats.isRenderable)
        XCTAssertEqual(stats.backgroundInstances, 1)
        XCTAssertEqual(stats.cursorInstances, 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(
            &pixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(5, 5, 1, 1),
            mipmapLevel: 0
        )
        // BGRA: the top-left cell's blue background, opaque.
        XCTAssertEqual(pixel[0], 255)
        XCTAssertEqual(pixel[1], 0)
        XCTAssertEqual(pixel[2], 0)
        XCTAssertEqual(pixel[3], 255)

        // The cursor cell is the ember cursor color, not the clear color.
        var cursorPixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(
            &cursorPixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(15, 30, 1, 1),
            mipmapLevel: 0
        )
        XCTAssertEqual(cursorPixel[2], 0xf4)
        XCTAssertEqual(cursorPixel[1], 0x58)
        XCTAssertEqual(cursorPixel[0], 0x1c)

        // Three more frames fill the ring; a fourth must reuse, not allocate.
        for _ in 0..<3 { _ = renderOnce() }
        let allocations = renderer.bufferAllocationCount
        XCTAssertGreaterThan(allocations, 0)
        for _ in 0..<4 { _ = renderOnce() }
        XCTAssertEqual(renderer.bufferAllocationCount, allocations, "instance buffers must be reused")
    }

    // MARK: - Row-level Cache

    func testRowLevelCacheReusesUndamagedRowsAndRebuildsDamagedOnes() {
        let planner = self.planner()
        var f = frame(cols: 4, rows: 4)

        let initial = planner.plan(frame: f, viewport: viewport)
        XCTAssertEqual(initial.replannedRows, 4)
        XCTAssertEqual(initial.replannedCells, 16)

        // Undamaged
        f = frame(cols: 4, rows: 4, damagedRows: [])
        let cached = planner.plan(frame: f, viewport: viewport)
        XCTAssertEqual(cached.replannedRows, 0)
        XCTAssertEqual(cached.replannedCells, 0)
        XCTAssertEqual(cached.backgroundInstances, initial.backgroundInstances)

        // One damaged row
        f = frame(cols: 4, rows: 4, damagedRows: [2])
        let oneDamaged = planner.plan(frame: f, viewport: viewport)
        XCTAssertEqual(oneDamaged.replannedRows, 1)
        XCTAssertEqual(oneDamaged.replannedCells, 4)

        // Multiple damaged rows
        f = frame(cols: 4, rows: 4, damagedRows: [0, 3])
        let multipleDamaged = planner.plan(frame: f, viewport: viewport)
        XCTAssertEqual(multipleDamaged.replannedRows, 2)
        XCTAssertEqual(multipleDamaged.replannedCells, 8)

        // Full damaged rows
        f = frame(cols: 4, rows: 4, damagedRows: [0, 1, 2, 3])
        let fullDamaged = planner.plan(frame: f, viewport: viewport)
        XCTAssertEqual(fullDamaged.replannedRows, 4)
        XCTAssertEqual(fullDamaged.replannedCells, 16)
    }

    func testRowLevelCacheReusesCellsWhenOnlyCursorBlinksOrSelectionChanges() {
        let planner = self.planner()
        let f = frame(cols: 4, rows: 4, cursorVisible: true, cursorRow: 1, blinking: false)
        planner.plan(frame: f, viewport: viewport)

        let f2 = frame(cols: 4, rows: 4, cursorVisible: true, cursorRow: 1, blinking: true, selection: selection(0, 0, 0, 1, .linear), damagedRows: [])
        let cached = planner.plan(frame: f2, viewport: viewport)

        XCTAssertEqual(cached.replannedRows, 0, "cursor and selection changes do not invalidate cell passes")
    }

    func testRowLevelCacheInvalidatesOnResize() {
        let planner = self.planner()
        planner.plan(frame: frame(cols: 4, rows: 4), viewport: viewport)

        let resized = frame(cols: 5, rows: 4)
        let stats = planner.plan(frame: resized, viewport: viewport)
        XCTAssertEqual(stats.replannedRows, 4, "resize must fully invalidate")
    }

    func testRowLevelCacheInvalidatesOnFocusOrPaletteChange() {
        let planner = self.planner()
        planner.plan(frame: frame(cols: 4, rows: 4), viewport: viewport)

        planner.isFocused = false
        let unfocused = planner.plan(frame: frame(cols: 4, rows: 4), viewport: viewport)
        XCTAssertEqual(unfocused.replannedRows, 4, "focus change must fully invalidate")

        planner.palette.background = SIMD4<Float>(1, 1, 1, 1)
        let paletteChanged = planner.plan(frame: frame(cols: 4, rows: 4), viewport: viewport)
        XCTAssertEqual(paletteChanged.replannedRows, 4, "palette change must fully invalidate")
    }

    func testRowLevelCacheRetainsWideContinuationsDecorationsAndColorGlyphs() {
        let planner = self.planner()
        var cells = Array(repeating: CellSpec(), count: 4 * 4)
        cells[0].ch = 0x1F600 // color emoji
        cells[1].bits = CellSpec.wideBit | CellSpec.underlineBit
        let f = frame(cols: 4, rows: 4, cells: cells)

        let initial = planner.plan(frame: f, viewport: viewport)
        XCTAssertEqual(initial.colorGlyphInstances, 1)
        XCTAssertGreaterThan(initial.decorationInstances, 0)

        let f2 = frame(cols: 4, rows: 4, cells: cells, damagedRows: [2])
        let cached = planner.plan(frame: f2, viewport: viewport)

        XCTAssertEqual(cached.replannedRows, 1)
        XCTAssertEqual(cached.colorGlyphInstances, initial.colorGlyphInstances)
        XCTAssertEqual(cached.decorationInstances, initial.decorationInstances)
    }

    func testRowLevelCacheInvalidatesAfterInvalidFrames() {
        let planner = self.planner()
        planner.plan(frame: frame(cols: 4, rows: 4), viewport: viewport)

        let invalid = frame(cols: 0, rows: 0, packedOverride: Data())
        let invalidStats = planner.plan(frame: invalid, viewport: viewport)
        XCTAssertEqual(invalidStats.replannedRows, 0)

        let recovered = planner.plan(frame: frame(cols: 4, rows: 4), viewport: viewport)
        XCTAssertEqual(recovered.replannedRows, 4, "valid frame after invalid frame must fully invalidate")
    }

    func testRowLevelCacheProducesExactlyTheFreshCellPassesAfterPartialDamage() {
        var initial = Array(repeating: CellSpec(), count: 4 * 3)
        for index in initial.indices {
            initial[index].ch = UInt32(0x41 + index)
        }
        initial[1].bg = (0x20, 0x30, 0x40)
        initial[5].bits = CellSpec.underlineBit
        initial[10].bits = CellSpec.strikethroughBit

        let cachedPlanner = planner()
        _ = cachedPlanner.plan(
            frame: frame(cols: 4, rows: 3, cells: initial),
            viewport: viewport
        )

        var final = initial
        final[4].bg = (0x70, 0x20, 0x10)
        final[5].fg = (0x10, 0xa0, 0xe0)
        final[6].bits = CellSpec.overlineBit
        let cachedStats = cachedPlanner.plan(
            frame: frame(cols: 4, rows: 3, cells: final, damagedRows: [1]),
            viewport: viewport
        )

        let freshPlanner = planner()
        let freshStats = freshPlanner.plan(
            frame: frame(cols: 4, rows: 3, cells: final),
            viewport: viewport
        )

        XCTAssertEqual(cachedStats.replannedRows, 1)
        XCTAssertEqual(cachedStats.replannedCells, 4)
        XCTAssertEqual(cachedPlanner.backgroundInstances, freshPlanner.backgroundInstances)
        XCTAssertEqual(cachedPlanner.glyphInstances, freshPlanner.glyphInstances)
        XCTAssertEqual(cachedPlanner.colorGlyphInstances, freshPlanner.colorGlyphInstances)
        XCTAssertEqual(cachedPlanner.decorationInstances, freshPlanner.decorationInstances)
        XCTAssertEqual(cachedStats.backgroundInstances, freshStats.backgroundInstances)
        XCTAssertEqual(cachedStats.glyphInstances, freshStats.glyphInstances)
        XCTAssertEqual(cachedStats.decorationInstances, freshStats.decorationInstances)
        XCTAssertEqual(cachedStats.skippedGlyphs, freshStats.skippedGlyphs)
    }

    func testLargeFrameReplansOnlyOneDirtyRowAndMatchesFreshFullPlan() {
        let cols = 100
        let rows = 50
        var initial = [CellSpec](repeating: CellSpec(), count: cols * rows)
        for index in initial.indices {
            initial[index].ch = index % 3 == 0 ? 0x41 : 0x42
            if index % 7 == 0 {
                initial[index].fg = (0x20, 0x30, 0x40)
                initial[index].bits = CellSpec.underlineBit
            }
        }

        let cachedPlanner = planner()
        let initialStats = cachedPlanner.plan(
            frame: frame(cols: UInt32(cols), rows: UInt32(rows), cells: initial),
            viewport: viewport
        )
        XCTAssertEqual(initialStats.replannedRows, rows)
        XCTAssertEqual(initialStats.replannedCells, cols * rows)

        var mutated = initial
        let dirtyRow = 17
        let rowStart = dirtyRow * cols
        for column in 0..<cols {
            let index = rowStart + column
            mutated[index].bg = (UInt8((column * 5) % 256), UInt8((column * 7) % 256), UInt8((column * 11) % 256))
            mutated[index].fg = (UInt8(255 - (column % 256)), UInt8((32 + column) % 256), UInt8((96 + column * 2) % 256))
            if column % 11 == 0 {
                mutated[index].bits = CellSpec.strikethroughBit
            }
            mutated[index].ch = column % 2 == 0 ? 0x41 : 0x42
        }

        let cachedStats = cachedPlanner.plan(
            frame: frame(cols: UInt32(cols), rows: UInt32(rows), cells: mutated, damagedRows: [UInt32(dirtyRow)]),
            viewport: viewport
        )
        XCTAssertEqual(cachedStats.replannedRows, 1)
        XCTAssertEqual(cachedStats.replannedCells, cols)

        let freshPlanner = planner()
        let freshStats = freshPlanner.plan(
            frame: frame(cols: UInt32(cols), rows: UInt32(rows), cells: mutated),
            viewport: viewport
        )
        XCTAssertEqual(cachedStats.backgroundInstances, freshStats.backgroundInstances)
        XCTAssertEqual(cachedPlanner.glyphInstances, freshPlanner.glyphInstances)
        XCTAssertEqual(cachedPlanner.colorGlyphInstances, freshPlanner.colorGlyphInstances)
        XCTAssertEqual(cachedPlanner.decorationInstances, freshPlanner.decorationInstances)
        XCTAssertEqual(cachedStats.skippedGlyphs, freshStats.skippedGlyphs)
        XCTAssertEqual(cachedStats.visitedCells, freshStats.visitedCells)
    }

    private func makeCells(lines: [String]) -> [CellSpec] {
        var cells: [CellSpec] = []
        for line in lines {
            for scalar in line.unicodeScalars {
                cells.append(CellSpec(ch: scalar.value))
            }
        }
        return cells
    }

    func testAdvisoryDamageDoesNotRetainDenseEraseAndRewriteRows() {
        let planner = self.planner()
        let cols: UInt32 = 10
        let rows: UInt32 = 4

        // Fill all 4 rows with glyphs
        let initialLines = ["Row0Full__", "Row1Full__", "Row2Full__", "Row3Full__"]
        let f1 = frame(cols: cols, rows: rows, cells: makeCells(lines: initialLines))
        let stats1 = planner.plan(frame: f1, viewport: viewport)
        XCTAssertEqual(stats1.glyphInstances, 40)

        // `renderFrame()` carries every packed row, but its damage list can
        // be incomplete when a delta consumer drained it first. Rewriting
        // just row 0 must therefore not retain the wrapped rows that were
        // erased from the complete payload.
        let rewrittenLines = ["Short     ", "          ", "          ", "          "]
        var f2 = frame(cols: cols, rows: rows, cells: makeCells(lines: rewrittenLines))
        f2.snapshot.damagedRows = [0]
        let stats2 = planner.plan(frame: f2, viewport: viewport)
        XCTAssertEqual(stats2.glyphInstances, 5, "erased rows 1..3 must have 0 glyph instances")
        XCTAssertEqual(stats2.replannedRows, 4)
        XCTAssertEqual(stats2.replannedCells, 40)

        // With byte-identical packed cells, no rows need rebuilding. The
        // exact advisory-damage verification has a bounded one-row-stride
        // cost per reused row (10 columns × 16 packed bytes × 4 rows).
        f2.snapshot.damagedRows = []
        let unchanged = planner.plan(frame: f2, viewport: viewport)
        XCTAssertEqual(unchanged.replannedRows, 0)
        XCTAssertEqual(unchanged.replannedCells, 0)
        XCTAssertEqual(unchanged.comparedPackedCellBytes, 640)
    }

    func testViewportAndAlternateScreenChangesInvalidateCachedRows() {
        let planner = self.planner()
        let cols: UInt32 = 10
        let rows: UInt32 = 4

        // 1. Initial live screen at offset 0
        let liveLines = ["LiveRow0__", "LiveRow1__", "LiveRow2__", "LiveRow3__"]
        let f0 = frame(cols: cols, rows: rows, cells: makeCells(lines: liveLines), viewportOffset: 0)
        _ = planner.plan(frame: f0, viewport: viewport)

        // 2. User scrolls up into history (offset = 5).
        let histLines = ["HistRow0__", "HistRow1__", "HistRow2__", "HistRow3__"]
        let f1 = frame(cols: cols, rows: rows, cells: makeCells(lines: histLines), viewportOffset: 5)
        let stats1 = planner.plan(frame: f1, viewport: viewport)
        XCTAssertEqual(stats1.glyphInstances, 40)

        // 3. User jumps back to live tail (offset = 0).
        // Damaged rows is [0] (e.g. only cursor/prompt updated).
        // The planner must NOT reuse rows 1..3 from the history frame.
        var f2 = frame(cols: cols, rows: rows, cells: makeCells(lines: liveLines), viewportOffset: 0)
        f2.snapshot.damagedRows = [0]
        let stats2 = planner.plan(frame: f2, viewport: viewport)
        XCTAssertEqual(stats2.glyphInstances, 40, "returning to tail must invalidate cached history rows")
        XCTAssertEqual(stats2.replannedRows, 4)

        let alternate = frame(
            cols: cols,
            rows: rows,
            cells: makeCells(lines: ["AltScreen0", "AltScreen1", "AltScreen2", "AltScreen3"]),
            alternateScreen: true,
            damagedRows: []
        )
        let alternateStats = planner.plan(frame: alternate, viewport: viewport)
        XCTAssertEqual(alternateStats.replannedRows, 4, "switching terminal grids invalidates every cached viewport row")
        XCTAssertEqual(alternateStats.glyphInstances, 40)
    }

    func testWrappedCoreFrameWithAdvisoryDamageMatchesFreshPlan() {
        let core = TakoCore(cols: 40, rows: 10)
        let planner = self.planner()

        // 1. Fill screen with multi-line text
        core.feed(bytes: Data("Line 1: Hello World\r\nLine 2: Second Line\r\nLine 3: Third Line\r\n".utf8))
        let f1 = core.renderFrame()
        _ = planner.plan(frame: f1, viewport: viewport)

        // 2. Dense cursor reposition + clear to end of screen + short replacement
        core.feed(bytes: Data("\u{1B}[1;1H\u{1B}[JDone!\r\n".utf8))
        var f2 = core.renderFrame()
        f2.snapshot.damagedRows = [0]
        let stats2 = planner.plan(frame: f2, viewport: viewport)
        // Only "Done!" on row 0 has glyphs; rows 1..9 are blank
        XCTAssertEqual(stats2.glyphInstances, 5, "erased rows must have 0 glyph instances after dense erase/rewrite")

        let freshPlanner = self.planner()
        let freshStats = freshPlanner.plan(frame: f2, viewport: viewport)
        XCTAssertEqual(planner.backgroundInstances, freshPlanner.backgroundInstances)
        XCTAssertEqual(planner.decorationInstances, freshPlanner.decorationInstances)
        XCTAssertEqual(stats2.glyphInstances, freshStats.glyphInstances)

        // 3. Scroll into history
        for i in 1...20 {
            core.feed(bytes: Data("Log line \(i)\r\n".utf8))
        }
        core.scrollViewportUp(lines: 5)
        let f3 = core.renderFrame()
        _ = planner.plan(frame: f3, viewport: viewport)

        // 4. Return to live tail
        core.scrollViewportBottom()
        var f4 = core.renderFrame()
        f4.snapshot.damagedRows = [0]
        let stats4 = planner.plan(frame: f4, viewport: viewport)
        let freshTailPlanner = self.planner()
        let freshTailStats = freshTailPlanner.plan(frame: f4, viewport: viewport)
        XCTAssertEqual(stats4.glyphInstances, freshTailStats.glyphInstances, "live tail must match authoritative grid glyph count without stale history rows")
        let visibleNonSpaceCount = (0..<10).flatMap { core.viewportRow(row: $0) }.filter { $0.ch > 32 }.count
        XCTAssertEqual(stats4.glyphInstances, visibleNonSpaceCount)
    }

    func testBlockCursorMovementAndBlinkReplansOnlyAffectedRows() {
        let planner = self.planner()
        let cols: UInt32 = 4
        let rows: UInt32 = 3
        var cells = Array(repeating: CellSpec(), count: Int(cols * rows))
        for index in cells.indices { cells[index].ch = 0x41 + UInt32(index) }

        let initial = frame(
            cols: cols,
            rows: rows,
            cells: cells,
            cursorVisible: true,
            cursorRow: 1,
            cursorCol: 1,
            blinking: true
        )
        _ = planner.plan(frame: initial, viewport: viewport)

        let moved = frame(
            cols: cols,
            rows: rows,
            cells: cells,
            cursorVisible: true,
            cursorRow: 2,
            cursorCol: 2,
            blinking: true,
            damagedRows: []
        )
        let movedStats = planner.plan(frame: moved, viewport: viewport)
        XCTAssertEqual(movedStats.replannedRows, 2, "both old and new block-cursor rows change glyph contrast")

        let freshMoved = self.planner()
        _ = freshMoved.plan(frame: moved, viewport: viewport)
        XCTAssertEqual(planner.glyphInstances, freshMoved.glyphInstances)

        planner.cursorBlinkPhaseOn = false
        let blinkedOff = planner.plan(frame: moved, viewport: viewport)
        XCTAssertEqual(blinkedOff.replannedRows, 1, "hiding a block cursor restores its row's glyph color")

        planner.cursorBlinkPhaseOn = true
        let blinkedOn = planner.plan(frame: moved, viewport: viewport)
        XCTAssertEqual(blinkedOn.replannedRows, 1, "showing a block cursor reapplies its row's glyph contrast")
    }

    func testClaudeAlternateScreenHistorySwipesAndReverseRestorationConcatenationDefect() {
        let planner = self.planner()
        let cols: UInt32 = 80
        let rows: UInt32 = 53

        // 1. Initial 53-row portrait Claude-like alternate-screen transcript containing numbered rows 1 through 30
        var tailLines = (1...30).map { i -> String in
            let word: String
            switch i {
            case 27: word = "twenty-seven"
            case 28: word = "twenty-eight"
            case 29: word = "twenty-nine"
            case 30: word = "thirty"
            default: word = "line-\(i)"
            }
            let text = "\(i) \(word)"
            return text.padding(toLength: Int(cols), withPad: " ", startingAt: 0)
        }
        while tailLines.count < Int(rows) {
            tailLines.append(String(repeating: " ", count: Int(cols)))
        }

        let f0 = frame(
            cols: cols,
            rows: rows,
            cells: makeCells(lines: tailLines),
            alternateScreen: true,
            damagedRows: Array(0..<rows)
        )
        let stats0 = planner.plan(frame: f0, viewport: viewport)
        XCTAssertGreaterThan(stats0.glyphInstances, 0)

        // 2. Four native history swipes move viewport up into history
        var historyLines = (1...30).map { i -> String in
            let word: String
            switch i {
            case 27: word = "twenty-seven"
            case 28: word = "twenty-eight"
            case 29: word = "twenty-nine"
            case 30: word = "thirty"
            default: word = "hist-\(i)"
            }
            let text = "  \(word)"
            return text.padding(toLength: Int(cols), withPad: " ", startingAt: 0)
        }
        while historyLines.count < Int(rows) {
            historyLines.append(String(repeating: " ", count: Int(cols)))
        }

        let f1 = frame(
            cols: cols,
            rows: rows,
            cells: makeCells(lines: historyLines),
            alternateScreen: true,
            damagedRows: Array(0..<rows)
        )
        _ = planner.plan(frame: f1, viewport: viewport)

        // 3. Intermediate frame where rows 27-30 have both prefix numbers and lingering history text (e.g. 27twenty-seven)
        var interLines = historyLines
        interLines[26] = "27twenty-seven".padding(toLength: Int(cols), withPad: " ", startingAt: 0)
        interLines[27] = "28twenty-eight".padding(toLength: Int(cols), withPad: " ", startingAt: 0)
        interLines[28] = "29twenty-nine".padding(toLength: Int(cols), withPad: " ", startingAt: 0)
        interLines[29] = "30thirty".padding(toLength: Int(cols), withPad: " ", startingAt: 0)

        let fInter = frame(
            cols: cols,
            rows: rows,
            cells: makeCells(lines: interLines),
            alternateScreen: true,
            damagedRows: [26, 27, 28, 29]
        )
        _ = planner.plan(frame: fInter, viewport: viewport)

        // 4. Reverse swipes restore authoritative tail text: rows 27-30 only contain "27", "28", "29", "30" followed by spaces
        var restoredTailLines = tailLines
        restoredTailLines[26] = "27".padding(toLength: Int(cols), withPad: " ", startingAt: 0)
        restoredTailLines[27] = "28".padding(toLength: Int(cols), withPad: " ", startingAt: 0)
        restoredTailLines[28] = "29".padding(toLength: Int(cols), withPad: " ", startingAt: 0)
        restoredTailLines[29] = "30".padding(toLength: Int(cols), withPad: " ", startingAt: 0)

        // When damage list is advisory (drained or only row 0 reported)
        let fRestored = frame(
            cols: cols,
            rows: rows,
            cells: makeCells(lines: restoredTailLines),
            alternateScreen: true,
            damagedRows: [0]
        )
        let statsRestored = planner.plan(frame: fRestored, viewport: viewport)

        let freshPlanner = self.planner()
        let freshStats = freshPlanner.plan(frame: fRestored, viewport: viewport)

        XCTAssertEqual(
            statsRestored.glyphInstances,
            freshStats.glyphInstances,
            "Rendered Metal frame must not retain stale packed cells or concatenate old glyphs"
        )
        XCTAssertEqual(planner.glyphInstances, freshPlanner.glyphInstances)
    }
}
