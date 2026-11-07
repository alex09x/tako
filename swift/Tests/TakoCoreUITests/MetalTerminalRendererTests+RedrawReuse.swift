/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import XCTest
@testable import TakoCoreUI

extension MetalTerminalRendererTests {
    func testAdvisoryFullDamageReusesUnchangedPackedRows() {
        let planner = planner()
        var cells = [CellSpec](repeating: CellSpec(), count: 120 * 40)
        for index in cells.indices {
            cells[index].ch = UInt32(65 + index % 26)
            cells[index].fg = (0x80, 0xa0, 0xe0)
            if index % 5 == 0 { cells[index].bits = CellSpec.underlineBit }
        }
        let f = frame(cols: 120, rows: 40, cells: cells)
        _ = planner.plan(frame: f, viewport: viewport)
        let glyphs = planner.glyphInstances
        let decorations = planner.decorationInstances
        let start = CFAbsoluteTimeGetCurrent()
        var replanned = 0
        for _ in 0..<30 {
            replanned += planner.plan(frame: f, viewport: viewport).replannedRows
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("REDRAW_REUSE frames=30 cells=4800 replannedRows=\(replanned) elapsedMs=\(elapsed)")
        XCTAssertEqual(replanned, 0, "damage is advisory; identical rows need no new cell passes")
        XCTAssertEqual(planner.glyphInstances, glyphs)
        XCTAssertEqual(planner.decorationInstances, decorations)
        XCTAssertEqual(planner.changedRows.count, 40, "host link-metadata invalidation stays intact")
    }

    func testFullDamageReplansOnlyChangedRowsAndMatchesFreshOutput() {
        let planner = planner()
        var cells = [CellSpec](repeating: CellSpec(), count: 12 * 6)
        for index in cells.indices { cells[index].ch = UInt32(65 + index % 26) }
        _ = planner.plan(frame: frame(cols: 12, rows: 6, cells: cells), viewport: viewport)
        cells[25].ch = 0x5a
        cells[26].fg = (0x20, 0xd0, 0x90)
        cells[27].bg = (0x30, 0x40, 0x70)
        cells[28].bits = CellSpec.underlineBit | CellSpec.boldBit
        let changed = frame(cols: 12, rows: 6, cells: cells)
        let stats = planner.plan(frame: changed, viewport: viewport)
        let fresh = self.planner()
        _ = fresh.plan(frame: changed, viewport: viewport)
        XCTAssertEqual(stats.replannedRows, 1)
        XCTAssertEqual(stats.replannedCells, 12)
        XCTAssertEqual(planner.changedRows, IndexSet(integersIn: 0..<6))
        XCTAssertEqual(planner.backgroundInstances, fresh.backgroundInstances)
        XCTAssertEqual(planner.glyphInstances, fresh.glyphInstances)
        XCTAssertEqual(planner.colorGlyphInstances, fresh.colorGlyphInstances)
        XCTAssertEqual(planner.decorationInstances, fresh.decorationInstances)
    }

    func testRealTUIEraseAndRedrawReusesUnchangedRows() {
        let core = TakoCore(cols: 40, rows: 10)
        let planner = planner()
        let redraw = "\u{1b}[H\u{1b}[2J" + (0..<10).map {
            "\u{1b}[\($0 + 1);1H\u{1b}[38;2;100;180;220mAgent response row \($0)"
        }.joined()
        core.feed(bytes: Data(("\u{1b}[?1049h\u{1b}[?25l" + redraw).utf8))
        let first = core.renderFrame()
        _ = planner.plan(frame: first, viewport: viewport)
        let glyphs = planner.glyphInstances
        core.feed(bytes: Data(redraw.utf8))
        let repeated = core.renderFrame()
        XCTAssertFalse(repeated.snapshot.damagedRows.isEmpty, "real erase/rewrite must exercise damage")
        XCTAssertEqual(repeated.packedCells, first.packedCells)
        let stats = planner.plan(frame: repeated, viewport: viewport)
        XCTAssertEqual(stats.replannedRows, 0)
        XCTAssertEqual(planner.glyphInstances, glyphs)
    }

    func testAtlasClearInvalidatesEqualRowsBeforeReusingGlyphCoordinates() {
        let planner = planner()
        var cells = [CellSpec](repeating: CellSpec(), count: 12)
        for index in cells.indices { cells[index].ch = UInt32(65 + index) }
        let f = frame(cols: 4, rows: 3, cells: cells)
        _ = planner.plan(frame: f, viewport: viewport)
        planner.atlas.clear()
        let stats = planner.plan(frame: f, viewport: viewport)
        XCTAssertEqual(stats.replannedRows, 3)
        XCTAssertEqual(stats.glyphInstances, 12)
        XCTAssertGreaterThan(planner.atlas.cachedCount, 0)
        XCTAssertEqual(planner.plan(frame: f, viewport: viewport).replannedRows, 0)
    }

    func testChangedGraphemeReplansDespiteEqualPackedCells() {
        let planner = planner()
        var cells = [CellSpec](repeating: CellSpec(), count: 12 * 3)
        cells[0].ch = 0x65
        cells[0].bits = 1 << 10 // side-table grapheme, same base scalar
        var first = frame(cols: 12, rows: 3, cells: cells)
        first.graphemes = [FfiGrapheme(row: 0, col: 0, text: "e\u{20dd}")]
        _ = planner.plan(frame: first, viewport: viewport)
        var changed = first
        changed.graphemes = [FfiGrapheme(row: 0, col: 0, text: "e\u{20de}")]
        XCTAssertEqual(first.packedCells, changed.packedCells)
        XCTAssertNotEqual(first.graphemes, changed.graphemes)
        XCTAssertEqual(planner.plan(frame: changed, viewport: viewport).replannedRows, 1)
    }
}
