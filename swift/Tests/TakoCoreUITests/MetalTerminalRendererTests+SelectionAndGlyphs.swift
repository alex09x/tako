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
import Metal
import XCTest
@testable import TakoCoreUI

extension MetalTerminalRendererTests {
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


}
