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

}
