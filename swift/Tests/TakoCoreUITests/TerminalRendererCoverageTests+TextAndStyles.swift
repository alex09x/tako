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
import CoreText
import ImageIO
import XCTest
@testable import TakoCoreUI

extension TerminalRendererCoverageTests {
    // MARK: - Selection Drawing

    func testDrawSelectionLinearAndRectangular() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let renderer = TerminalRenderer(
            metrics: metrics,
            selectionColor: srgb(r: 0, g: 0, b: 255)
        )

        // Multi-row linear selection: row 0 selects cols 1-3, row 1 selects
        // the whole row, row 2 selects cols 0-2. Each row's own bounds are
        // checked, not just "something got painted somewhere".
        let b1 = BitmapContext(width: 40, height: 60)
        let linearSel = FfiSelectionRange(
            startRow: 0,
            startCol: 1,
            endRow: 2,
            endCol: 2,
            mode: .linear
        )
        renderer.draw(
            in: b1.context,
            cols: 4,
            rows: 3,
            rowProvider: { _ in [] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: false,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            selection: linearSel,
            skipBackgrounds: true
        )
        XCTAssertEqual(b1.pixel(atX: 5, y: 10).a, 0) // row0 col0: not selected
        let row0Col1 = b1.pixel(atX: 15, y: 10) // row0 col1: selected
        XCTAssertGreaterThan(row0Col1.a, 0)
        assertColorApprox(row0Col1, (0, 0, 255))
        XCTAssertGreaterThan(b1.pixel(atX: 5, y: 30).a, 0) // row1 col0: full row selected
        XCTAssertGreaterThan(b1.pixel(atX: 15, y: 50).a, 0) // row2 col1: selected
        XCTAssertEqual(b1.pixel(atX: 35, y: 50).a, 0) // row2 col3: past endCol, not selected

        // Single-row branch: startRow == endRow, only that row is touched.
        let b2 = BitmapContext(width: 40, height: 40)
        let singleRowSel = FfiSelectionRange(
            startRow: 1,
            startCol: 1,
            endRow: 1,
            endCol: 3,
            mode: .linear
        )
        renderer.draw(
            in: b2.context,
            cols: 4,
            rows: 2,
            rowProvider: { _ in [] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: false,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            selection: singleRowSel,
            skipBackgrounds: true
        )
        XCTAssertEqual(b2.pixel(atX: 5, y: 10).a, 0) // row0: outside range entirely
        XCTAssertEqual(b2.pixel(atX: 5, y: 30).a, 0) // row1 col0: before startCol
        XCTAssertGreaterThan(b2.pixel(atX: 15, y: 30).a, 0) // row1 col1: selected
        XCTAssertGreaterThan(b2.pixel(atX: 35, y: 30).a, 0) // row1 col3: selected

        // Rectangular selection (including inverted cols): every row uses
        // the same column band, unlike linear's per-row bounds.
        let b3 = BitmapContext(width: 40, height: 60)
        let rectSel = FfiSelectionRange(
            startRow: 0,
            startCol: 3,
            endRow: 2,
            endCol: 1,
            mode: .rectangular
        )
        renderer.draw(
            in: b3.context,
            cols: 4,
            rows: 3,
            rowProvider: { _ in [] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: false,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            selection: rectSel,
            skipBackgrounds: true
        )
        for y in [10, 30, 50] {
            XCTAssertEqual(b3.pixel(atX: 5, y: y).a, 0, "col0 excluded at y=\(y)")
            XCTAssertGreaterThan(b3.pixel(atX: 35, y: y).a, 0, "col3 included at y=\(y)")
        }

        // Out of bounds selection (rows entirely outside the viewport).
        let b4 = BitmapContext(width: 40, height: 40)
        let oobSel = FfiSelectionRange(
            startRow: 5,
            startCol: 0,
            endRow: 8,
            endCol: 2,
            mode: .linear
        )
        renderer.draw(
            in: b4.context,
            cols: 4,
            rows: 2,
            rowProvider: { _ in [] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: false,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            selection: oobSel,
            skipBackgrounds: true
        )
        XCTAssertEqual(b4.nonZeroCount(xRange: 0..<40, yRange: 0..<40), 0)
    }

    // MARK: - Text Runs, Font Traits, and Cell Styles

    func testDrawRowTextRunsAndStyles() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let renderer = TerminalRenderer(
            metrics: metrics,
            defaultForeground: srgb(r: 255, g: 255, b: 255)
        )

        // 1. Background runs fill their own columns, in the run's colour,
        // and a cell matching the renderer's default background stays
        // unfilled -- checked per-column, not "some pixel changed".
        let cellsWithGlyph = [
            makeCell(ch: "H", bg: (200, 0, 0)),
            makeCell(ch: " ", bg: (200, 0, 0)),
            makeCell(ch: " ", bg: (0x14, 0x10, 0x0e)),
            makeCell(ch: " ", bg: (0, 255, 0)),
        ]
        let cellsBgOnly = [
            makeCell(ch: " ", bg: (200, 0, 0)),
            makeCell(ch: " ", bg: (200, 0, 0)),
            makeCell(ch: " ", bg: (0x14, 0x10, 0x0e)),
            makeCell(ch: " ", bg: (0, 255, 0)),
        ]
        let b1 = BitmapContext(width: 50, height: 20)
        renderer.drawRow(cellsWithGlyph, row: 0, rows: 1, in: b1.context, skipBackground: false)
        let b1BgOnly = BitmapContext(width: 50, height: 20)
        renderer.drawRow(cellsBgOnly, row: 0, rows: 1, in: b1BgOnly.context, skipBackground: false)

        // (col 0 also carries the "H" glyph, so its background colour is
        // sampled via col 1 -- same run, same colour, no glyph ink on top.)
        assertColorApprox(b1.pixel(atX: 15, y: 10), (200, 0, 0))
        XCTAssertEqual(b1.pixel(atX: 25, y: 10).a, 0) // matches renderer default bg: not filled
        assertColorApprox(b1.pixel(atX: 35, y: 10), (0, 255, 0))
        // The glyph itself adds ink beyond the flat background fill.
        XCTAssertGreaterThan(differingPixelCount(b1, b1BgOnly), 0)

        // 2. Bold and italic traits change the glyph's shape, not just its
        // presence: each render must differ from the plain glyph.
        func renderStyled(bold: Bool = false, italic: Bool = false) -> BitmapContext {
            let ctx = BitmapContext(width: 20, height: 20)
            renderer.drawRow(
                [makeCell(ch: "M", bold: bold, italic: italic)],
                row: 0, rows: 1, in: ctx.context, skipBackground: true
            )
            return ctx
        }
        let regular = renderStyled()
        let bold = renderStyled(bold: true)
        let italic = renderStyled(italic: true)
        let boldItalic = renderStyled(bold: true, italic: true)
        XCTAssertGreaterThan(differingPixelCount(bold, regular), 0)
        XCTAssertGreaterThan(differingPixelCount(italic, regular), 0)
        XCTAssertGreaterThan(differingPixelCount(boldItalic, regular), 0)
        XCTAssertGreaterThan(differingPixelCount(boldItalic, bold), 0)

        // 3. Dim text lowers alpha (~0.55) without moving the glyph.
        func renderBlock(dim: Bool) -> BitmapContext {
            let ctx = BitmapContext(width: 10, height: 20)
            renderer.drawRow(
                [makeCell(ch: "█", dim: dim)],
                row: 0, rows: 1, in: ctx.context, skipBackground: true
            )
            return ctx
        }
        let bright = renderBlock(dim: false)
        let dim = renderBlock(dim: true)
        let brightPixel = bright.pixel(atX: 5, logicalY: 10)
        let dimPixel = dim.pixel(atX: 5, logicalY: 10)
        XCTAssertGreaterThan(brightPixel.a, dimPixel.a)
        XCTAssertTrue(approx(brightPixel.a, 255, tolerance: 10))
        XCTAssertTrue(approx(dimPixel.a, 140, tolerance: 30))

        // 4. Hidden text: the glyph region must match a background-only
        // (blank) render exactly -- not merely "few pixels".
        let b4 = BitmapContext(width: 20, height: 20)
        renderer.drawRow([makeCell(ch: "H", hidden: true)], row: 0, rows: 1, in: b4.context, skipBackground: true)
        let b4Blank = BitmapContext(width: 20, height: 20)
        renderer.drawRow([makeCell(ch: " ")], row: 0, rows: 1, in: b4Blank.context, skipBackground: true)
        XCTAssertEqual(differingPixelCount(b4, b4Blank), 0)

        // 5. Whitespace-only without decoration draws nothing at all.
        let b5 = BitmapContext(width: 30, height: 20)
        let cells5 = [makeCell(ch: " "), makeCell(ch: " ")]
        renderer.drawRow(cells5, row: 0, rows: 1, in: b5.context, skipBackground: true)
        XCTAssertEqual(b5.nonZeroCount(xRange: 0..<30, yRange: 0..<20), 0)

        // 6. Whitespace-only WITH decoration draws only the decoration band,
        // not the rest of the (otherwise empty) cell.
        let b6 = BitmapContext(width: 30, height: 20)
        let cells6 = [
            makeCell(ch: " ", underline: true),
            makeCell(ch: " ", underline: true),
        ]
        renderer.drawRow(cells6, row: 0, rows: 1, in: b6.context, skipBackground: true)
        let underlineBase = Int(metrics.baseline) - 2
        XCTAssertTrue(isInk(b6, x: 5, logicalY: underlineBase))
        XCTAssertFalse(isInk(b6, x: 5, logicalY: 10))

        // 7. Non-ASCII scalar text (>= 128) still produces ink in its cell.
        let b7 = BitmapContext(width: 30, height: 20)
        let cells7 = [makeCell(ch: "Ж")]
        renderer.drawRow(cells7, row: 0, rows: 1, in: b7.context, skipBackground: true)
        XCTAssertGreaterThan(b7.nonZeroCount(xRange: 0..<10, yRange: 0..<20), 0)

        // 8. Reverse video: SGR 7 paints the glyph in the resolved
        // background colour, not the foreground colour.
        let b8 = BitmapContext(width: 20, height: 20)
        renderer.drawRow(
            [makeCell(ch: "█", fg: (0, 0, 255), bg: (255, 255, 0), reverse: true)],
            row: 0, rows: 1, in: b8.context, skipBackground: true
        )
        assertColorApprox(b8.pixel(atX: 5, logicalY: 10), (255, 255, 0))
    }


}
