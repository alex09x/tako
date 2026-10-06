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
    // MARK: - Underline Styles

    func testDrawUnderlineStyles() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let renderer = TerminalRenderer(metrics: metrics)
        // Use 2 rows and draw into row 0, so the double-underline's second
        // stripe (3px above the base line) has headroom above the canvas
        // edge instead of being clipped off.
        let rows = 2
        let row = 0
        let canvasWidth = 10
        let canvasHeight = 40
        let rowY = Int(CGFloat(rows - 1 - row) * metrics.cellHeight)
        let base = rowY + Int(metrics.baseline) - 2

        func render(style: UInt8, underline: Bool = true) -> BitmapContext {
            let ctx = BitmapContext(width: canvasWidth, height: canvasHeight)
            renderer.drawRow(
                [makeCell(ch: "A", underline: underline, underlineStyle: style)],
                row: row, rows: rows, in: ctx.context, skipBackground: true
            )
            return ctx
        }

        let plain = render(style: 0, underline: false)
        let single = render(style: 1)
        let styleDefault = render(style: 0)
        let double = render(style: 2)
        let curly = render(style: 3)
        let dotted = render(style: 4)
        let dashed = render(style: 5)

        // The underline band differs from a render with no underline at all.
        XCTAssertGreaterThan(differingPixelCount(single, plain), 0)

        // Style 0 (unspecified) and style 1 (single) share the `default:`
        // case in the switch, so they must render identically.
        XCTAssertEqual(differingPixelCount(styleDefault, single), 0)

        // Single: one full-width solid row at `base`, nothing at the
        // second row double-underline uses, and nothing above the band.
        XCTAssertEqual(inkCount(single, xRange: 0..<10, logicalYRange: base..<(base + 1)), 10)
        XCTAssertFalse(isInk(single, x: 5, logicalY: base - 3))
        XCTAssertFalse(isInk(single, x: 5, logicalY: base + 1))

        // Double: solid rows at both `base` and `base - 3` -- the second
        // stripe single-underline never draws.
        XCTAssertEqual(inkCount(double, xRange: 0..<10, logicalYRange: base..<(base + 1)), 10)
        XCTAssertEqual(inkCount(double, xRange: 0..<10, logicalYRange: (base - 3)..<(base - 2)), 10)

        // Curly: the wave's amplitude reaches above `base` near the peak of
        // its first hump (around x=2.5, one quarter into the period),
        // unlike every other style, which stays confined to exactly one
        // (or two) flat rows.
        XCTAssertGreaterThan(inkCount(curly, xRange: 1..<4, logicalYRange: (base + 1)..<(base + 2)), 0)
        XCTAssertFalse(isInk(single, x: 2, logicalY: base + 1))
        XCTAssertFalse(isInk(double, x: 2, logicalY: base + 1))
        XCTAssertFalse(isInk(dotted, x: 2, logicalY: base + 1))
        XCTAssertFalse(isInk(dashed, x: 2, logicalY: base + 1))

        // Dotted: 1px dots every 2px -- columns 0,2,4,6,8 painted, the rest
        // are gaps. A solid single-underline would paint every column.
        XCTAssertTrue(isInk(dotted, x: 0, logicalY: base))
        XCTAssertFalse(isInk(dotted, x: 1, logicalY: base))
        XCTAssertTrue(isInk(dotted, x: 2, logicalY: base))
        XCTAssertEqual(inkCount(dotted, xRange: 0..<10, logicalYRange: base..<(base + 1)), 5)

        // Dashed: 4px dashes separated by 3px gaps -- a different mask from
        // both the solid single line and the sparser dotted line.
        XCTAssertTrue(isInk(dashed, x: 1, logicalY: base))
        XCTAssertFalse(isInk(dashed, x: 5, logicalY: base))
        XCTAssertTrue(isInk(dashed, x: 8, logicalY: base))
        XCTAssertEqual(inkCount(dashed, xRange: 0..<10, logicalYRange: base..<(base + 1)), 7)
    }

    // MARK: - Strikethrough and Overline

    func testDrawStrikethroughAndOverline() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let renderer = TerminalRenderer(metrics: metrics)
        let strikeY = Int(metrics.cellHeight / 2)
        let overlineY = Int(metrics.cellHeight) - 1

        // A blank cell isolates the decoration band from any glyph ink --
        // "A" has body strokes that can cross either row on its own.
        let plain = BitmapContext(width: 30, height: 20)
        renderer.drawRow([makeCell(ch: " ")], row: 0, rows: 1, in: plain.context, skipBackground: true)

        let b1 = BitmapContext(width: 30, height: 20)
        renderer.drawRow([makeCell(ch: " ", strikethrough: true)], row: 0, rows: 1, in: b1.context, skipBackground: true)
        let strikePixel = b1.pixel(atX: 5, logicalY: strikeY)
        XCTAssertGreaterThan(strikePixel.a, 0)
        assertColorApprox(strikePixel, (255, 255, 255))
        XCTAssertFalse(isInk(b1, x: 5, logicalY: overlineY)) // not the overline row
        XCTAssertGreaterThan(differingPixelCount(b1, plain), 0)

        let b2 = BitmapContext(width: 30, height: 20)
        renderer.drawRow([makeCell(ch: " ", overline: true)], row: 0, rows: 1, in: b2.context, skipBackground: true)
        let overlinePixel = b2.pixel(atX: 5, logicalY: overlineY)
        XCTAssertGreaterThan(overlinePixel.a, 0)
        assertColorApprox(overlinePixel, (255, 255, 255))
        XCTAssertFalse(isInk(b2, x: 5, logicalY: strikeY)) // not the strikethrough row
        XCTAssertGreaterThan(differingPixelCount(b2, plain), 0)
    }

    // MARK: - Fitted Glyphs, Box Drawing, Powerline, and Wide Characters

    func testDrawFittedGlyphsAndBoxDrawing() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let renderer = TerminalRenderer(metrics: metrics)
        let cellBand = 0..<20

        // Box drawing horizontal line (mustFillCell) vs a full block
        // (also mustFillCell): `mustFillCell` only stretches a glyph
        // horizontally (drawFitted only ever scales the x axis), so a
        // one-line-thick separator still occupies far fewer rows than a
        // block that is meant to cover the whole cell.
        let b1 = BitmapContext(width: 30, height: 20)
        renderer.drawRow([makeCell(ch: "─")], row: 0, rows: 1, in: b1.context, skipBackground: true)
        let lineSpan = inkRowSpan(b1, xRange: 0..<10, logicalYRange: cellBand)
        XCTAssertGreaterThan(lineSpan, 0)

        let b2 = BitmapContext(width: 30, height: 20)
        renderer.drawRow([makeCell(ch: "█")], row: 0, rows: 1, in: b2.context, skipBackground: true)
        let blockSpan = inkRowSpan(b2, xRange: 0..<10, logicalYRange: cellBand)
        XCTAssertGreaterThan(blockSpan, lineSpan * 2)

        // Filled square vs hollow square: the filled square's ink covers
        // far more of the cell than the hollow square's outline-only ink.
        let b3 = BitmapContext(width: 30, height: 20)
        renderer.drawRow([makeCell(ch: "■")], row: 0, rows: 1, in: b3.context, skipBackground: true)
        let filledCount = inkCount(b3, xRange: 0..<10, logicalYRange: cellBand)
        XCTAssertGreaterThan(filledCount, 0)

        let b3b = BitmapContext(width: 30, height: 20)
        renderer.drawRow([makeCell(ch: "□")], row: 0, rows: 1, in: b3b.context, skipBackground: true)
        let hollowCount = inkCount(b3b, xRange: 0..<10, logicalYRange: cellBand)
        XCTAssertGreaterThan(hollowCount, 0)
        XCTAssertGreaterThan(filledCount, hollowCount)

        // Powerline separator (mustFillCell): produces ink in its cell.
        let b4 = BitmapContext(width: 30, height: 20)
        let plCell = makeCellWithScalar(scalar: 0xE0B0)
        renderer.drawRow([plCell], row: 0, rows: 1, in: b4.context, skipBackground: true)
        XCTAssertGreaterThan(b4.nonZeroCount(xRange: 0..<10, yRange: 0..<20), 0)

        // CJK wide character (not mustFillCell): centred at natural size,
        // so it leaves empty margins at both edges of the 2-cell span --
        // unlike a must-fill glyph, which is scaled edge to edge.
        let b5 = BitmapContext(width: 40, height: 20)
        let cjkHead = makeCell(ch: "中", wide: true)
        let cjkTail = makeCellWithScalar(scalar: 0) // Tail cell ch == 0
        renderer.drawRow([cjkHead, cjkTail], row: 0, rows: 1, in: b5.context, skipBackground: true)
        XCTAssertGreaterThan(b5.nonZeroCount(xRange: 0..<20, yRange: 0..<20), 0)
        XCTAssertEqual(b5.nonZeroCount(xRange: 0..<1, yRange: 0..<20), 0)
        XCTAssertEqual(b5.nonZeroCount(xRange: 19..<20, yRange: 0..<20), 0)

        // Wide cell with mustFillCell = false (e.g. "A" with wide = true):
        // same centred-with-margins behaviour as the CJK glyph above.
        let b5b = BitmapContext(width: 40, height: 20)
        let wideAscii = makeCell(ch: "A", wide: true)
        renderer.drawRow([wideAscii, cjkTail], row: 0, rows: 1, in: b5b.context, skipBackground: true)
        XCTAssertGreaterThan(b5b.nonZeroCount(xRange: 0..<20, yRange: 0..<20), 0)
        XCTAssertEqual(b5b.nonZeroCount(xRange: 0..<1, yRange: 0..<20), 0)
        XCTAssertEqual(b5b.nonZeroCount(xRange: 19..<20, yRange: 0..<20), 0)

        // Wide cell with mustFillCell = true (scaled): reaches the far edge
        // of the second cell, where the centred glyphs above stayed empty.
        let b5c = BitmapContext(width: 40, height: 20)
        let wideBox = makeCell(ch: "─", wide: true)
        renderer.drawRow([wideBox, cjkTail], row: 0, rows: 1, in: b5c.context, skipBackground: true)
        XCTAssertGreaterThan(inkCount(b5c, xRange: 19..<20, logicalYRange: cellBand), 0)

        // Zero-width character (width <= 0.01 early return): draws nothing.
        let b6 = BitmapContext(width: 30, height: 20)
        let zwCell = makeCellWithScalar(scalar: 0x200B) // Zero-width space
        renderer.drawRow([zwCell], row: 0, rows: 1, in: b6.context, skipBackground: true)
        XCTAssertEqual(b6.nonZeroCount(xRange: 0..<10, yRange: 0..<20), 0)
    }

    // MARK: - Marked Text Drawing

    func testDrawMarkedTextRendering() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let renderer = TerminalRenderer(metrics: metrics)
        let defaultFg: (UInt8, UInt8, UInt8) = (0xed, 0xe6, 0xdf)
        let defaultBg: (UInt8, UInt8, UInt8) = (0x14, 0x10, 0x0e)

        // Empty text early return: nothing is drawn.
        let b1 = BitmapContext(width: 60, height: 40)
        renderer.drawMarkedText("", cursorCol: 0, cols: 6, availableRows: 2, y: 20, in: b1.context)
        XCTAssertEqual(b1.nonZeroCount(xRange: 0..<60, yRange: 0..<40), 0)

        // Single line, whitespace only: isolates the background fill and
        // underline decoration from any glyph ink, so their exact bounds
        // and colours can be checked without guessing at glyph shapes.
        let bSpaces = BitmapContext(width: 80, height: 40)
        renderer.drawMarkedText("   ", cursorCol: 1, cols: 8, availableRows: 2, y: 20, in: bSpaces.context)
        let base = 20 + Int(metrics.baseline) - 2
        assertColorApprox(bSpaces.pixel(atX: 15, logicalY: 30), defaultBg) // inside the fill, away from the underline row
        XCTAssertEqual(bSpaces.pixel(atX: 5, logicalY: 30).a, 0) // before the line's columns
        XCTAssertEqual(bSpaces.pixel(atX: 45, logicalY: 30).a, 0) // after the line's columns
        assertColorApprox(bSpaces.pixel(atX: 15, logicalY: base), defaultFg) // the underline row
        XCTAssertEqual(bSpaces.pixel(atX: 15, logicalY: 10).a, 0) // below the line entirely

        // Single line with real text: glyph ink is the only difference from
        // a same-length whitespace control -- both share the same
        // background fill and underline, so any pixel difference between
        // them must be actual glyph ink, not just "some pixel changed".
        let bSpacesSameLength = BitmapContext(width: 80, height: 40)
        renderer.drawMarkedText("     ", cursorCol: 1, cols: 8, availableRows: 2, y: 20, in: bSpacesSameLength.context)
        let b2 = BitmapContext(width: 80, height: 40)
        renderer.drawMarkedText("input", cursorCol: 1, cols: 8, availableRows: 2, y: 20, in: b2.context)
        XCTAssertGreaterThan(differingPixelCount(b2, bSpacesSameLength), 0)

        // Multiline wrapping marked text: the preedit follows terminal
        // wrapping and keeps only the most recent `availableRows` lines.
        // The final wrapped line is shorter than the rest, so its
        // background fill must stop at its own column bound, not extend
        // to the full width the earlier (full) lines use.
        let b3 = BitmapContext(width: 80, height: 60)
        renderer.drawMarkedText("verylongmarkedtext", cursorCol: 2, cols: 6, availableRows: 3, y: 40, in: b3.context)
        XCTAssertGreaterThan(b3.pixel(atX: 5, logicalY: 10).a, 0) // last line, within its own 2-column range
        XCTAssertEqual(b3.pixel(atX: 25, logicalY: 10).a, 0) // last line, past its own range
        XCTAssertGreaterThan(b3.pixel(atX: 55, logicalY: 30).a, 0) // a full-width earlier line
        XCTAssertGreaterThan(b3.pixel(atX: 55, logicalY: 50).a, 0) // another full-width earlier line
    }


}
