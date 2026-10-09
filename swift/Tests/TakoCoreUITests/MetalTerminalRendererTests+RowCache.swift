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

    func makeCells(lines: [String]) -> [CellSpec] {
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


}
