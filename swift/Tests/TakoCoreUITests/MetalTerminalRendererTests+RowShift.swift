/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest
@testable import TakoCoreUI

/// Output that scrolls moves rows the last frame planned: they are moved,
/// not laid out again, and the frame is exactly what a fresh plan draws.
extension MetalTerminalRendererTests {
    /// Rows of distinct text with colors and an underline, like a log.
    private func logCells(_ lines: [String], cols: Int) -> [CellSpec] {
        var cells: [CellSpec] = []
        for line in lines {
            let scalars = Array(line.unicodeScalars)
            // Styled by what the line says, as output is, not by where it is.
            let underlined = "bd".unicodeScalars.contains(scalars[0])
            for col in 0..<cols {
                var cell = CellSpec()
                if col < scalars.count { cell.ch = scalars[col].value }
                if col == 0 { cell.fg = (0xff, 0x7a, 0x3d) }
                if underlined && col == 1 { cell.bits = CellSpec.underlineBit; cell.underlineStyle = 1 }
                if col == 2 { cell.bg = (0x24, 0x1c, 0x16) }
                cells.append(cell)
            }
        }
        return cells
    }

    private func instances(_ planner: TerminalMetalFramePlanner) -> [String] {
        planner.backgroundInstances.map { "bg \($0.rect) \($0.color)" }
            + planner.glyphInstances.map { "g \($0.destRect) \($0.uvRect) \($0.color) \($0.atlasPage)" }
            + planner.colorGlyphInstances.map { "c \($0.destRect) \($0.uvRect)" }
            + planner.decorationInstances.map { "d \($0.rect) \($0.style)" }
    }

    func testScrolledOutputMovesPlannedRowsAndDrawsWhatAFreshPlanDraws() {
        let cols = 6
        let before = logCells(["aaaa", "bbbb", "cccc", "dddd"], cols: cols)
        let after = logCells(["bbbb", "cccc", "dddd", "eeee"], cols: cols)
        // The engine reports every row damaged when output scrolls.
        let scrolled = frame(cols: UInt32(cols), rows: 4, cells: after, damagedRows: [0, 1, 2, 3])

        let streaming = planner()
        streaming.plan(frame: frame(cols: UInt32(cols), rows: 4, cells: before), viewport: viewport)
        let stats = streaming.plan(frame: scrolled, viewport: viewport)

        XCTAssertEqual(stats.shiftedRows, 3, "bbbb, cccc and dddd moved up a row")
        XCTAssertEqual(stats.replannedRows, 1, "only the new line is laid out")

        // The same atlas, so glyphs sit at the same places in it.
        let fresh = TerminalMetalFramePlanner(metrics: metrics(), atlas: streaming.atlas)
        fresh.plan(frame: scrolled, viewport: viewport)
        XCTAssertEqual(instances(streaming), instances(fresh))
    }

    func testRowsUnderTheCursorOrASelectionAreNotMoved() {
        let cols = 6
        let before = logCells(["aaaa", "bbbb", "cccc", "dddd"], cols: cols)
        let after = logCells(["bbbb", "cccc", "dddd", "eeee"], cols: cols)
        let streaming = planner()
        streaming.plan(frame: frame(cols: UInt32(cols), rows: 4, cells: before,
                                    cursorVisible: true, cursorRow: 2, cursorCol: 1), viewport: viewport)
        let scrolled = frame(cols: UInt32(cols), rows: 4, cells: after,
                             cursorVisible: true, cursorRow: 0, cursorCol: 1, damagedRows: [0, 1, 2, 3])
        let stats = streaming.plan(frame: scrolled, viewport: viewport)
        // cccc had the cursor last frame and bbbb (row 0) has it now.
        XCTAssertEqual(stats.shiftedRows, 1, "only dddd moves")

        let fresh = TerminalMetalFramePlanner(metrics: metrics(), atlas: streaming.atlas)
        fresh.plan(frame: scrolled, viewport: viewport)
        XCTAssertEqual(instances(streaming), instances(fresh))
    }

    /// A streaming log on the user's screen size: 215 x 40, one new line a
    /// frame. Prints both timings; asserts on the work, which is exact.
    func testAScrollingLogLaysOutOneRowAFrame() {
        let cols = 215, rows = 40, frames = 300
        let lines = (0..<(rows + frames)).map {
            "[2026-10-17T01:50:13Z WARN  p2p_stream::diagnostics] event=batch_rejected round=\(1490069677 + $0) tx=0 offset=\($0 * 37)"
        }
        func run(shift: Bool) -> (seconds: Double, cells: Int) {
            let planner = self.planner()
            planner.rowShiftEnabled = shift
            let viewport = TerminalMetalViewport(drawableWidth: Float(cols * 10), drawableHeight: Float(rows * 20))
            var cells = 0
            var seconds = 0.0
            for n in 0..<frames {
                let screen = Array(lines[n..<(n + rows)])
                let next = frame(cols: UInt32(cols), rows: UInt32(rows), cells: logCells(screen, cols: cols))
                let start = CFAbsoluteTimeGetCurrent()
                let stats = planner.plan(frame: next, viewport: viewport)
                if n > 0 { cells += stats.replannedCells; seconds += CFAbsoluteTimeGetCurrent() - start }
            }
            return (seconds, cells)
        }
        let without = run(shift: false)
        let with = run(shift: true)
        print("scrolling log \(cols)x\(rows), \(frames) frames: laid out \(without.cells) cells in \(without.seconds)s without moving rows, \(with.cells) cells in \(with.seconds)s with")
        XCTAssertEqual(without.cells, (frames - 1) * cols * rows)
        XCTAssertEqual(with.cells, (frames - 1) * cols, "one new row a frame")
    }

    func testFractionalPixelRowsAreLaidOutAgain() {
        let planner = TerminalMetalFramePlanner(metrics: TerminalMetalCellMetrics(
            font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
            cellWidth: 10, cellHeight: 20.5, ascent: 15, scale: 1))
        XCTAssertFalse(planner.canShiftRows, "baselines round to pixels; a move by 20.5 would not")
    }
}
