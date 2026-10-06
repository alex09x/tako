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
    // MARK: - Metrics Tests

    func testMetricsFontResolutionAndFallbacks() {
        // Standard font request
        let m1 = TerminalRenderer.Metrics(fontSize: 12, fontName: "Menlo")
        XCTAssertGreaterThan(m1.cellWidth, 0)
        XCTAssertGreaterThan(m1.cellHeight, 0)
        XCTAssertGreaterThan(m1.baseline, 0)

        // Font request ending in -Regular (triggers suffix stripping branch)
        let m2 = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo-Regular")
        XCTAssertGreaterThan(m2.cellWidth, 0)
        XCTAssertGreaterThan(m2.cellHeight, 0)

        // Lowercase -regular suffix
        let m3 = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo-regular")
        XCTAssertGreaterThan(m3.cellWidth, 0)
        XCTAssertGreaterThan(m3.cellHeight, 0)

        // Non-existent font falls back to Menlo
        let m4 = TerminalRenderer.Metrics(fontSize: 14, fontName: "NonExistentFontName12345")
        XCTAssertGreaterThan(m4.cellWidth, 0)
        XCTAssertGreaterThan(m4.cellHeight, 0)

        // fontName nil uses default candidate list
        let m5 = TerminalRenderer.Metrics(fontSize: 14, fontName: nil)
        XCTAssertGreaterThan(m5.cellWidth, 0)
        XCTAssertGreaterThan(m5.cellHeight, 0)

        // Explicit cellWidth and cellHeight
        let m6 = TerminalRenderer.Metrics(fontSize: 12, fontName: "Menlo", cellWidth: 15, cellHeight: 30)
        XCTAssertEqual(m6.cellWidth, 15)
        XCTAssertEqual(m6.cellHeight, 30)

        // Non-positive or non-finite cellWidth/cellHeight uses derived dimensions
        let m7 = TerminalRenderer.Metrics(fontSize: 12, fontName: "Menlo", cellWidth: -5, cellHeight: 0)
        XCTAssertGreaterThan(m7.cellWidth, 0)
        XCTAssertGreaterThan(m7.cellHeight, 0)

        let m8 = TerminalRenderer.Metrics(fontSize: 12, fontName: "Menlo", cellWidth: .nan, cellHeight: .infinity)
        XCTAssertGreaterThan(m8.cellWidth, 0)
        XCTAssertGreaterThan(m8.cellHeight, 0)

        // Init with TerminalTheme
        let theme = TerminalTheme(
            fontFamily: "Menlo",
            fontSize: 16,
            cellWidth: 11,
            cellHeight: 22
        )
        let mTheme = TerminalRenderer.Metrics(theme: theme)
        XCTAssertEqual(mTheme.cellWidth, 11)
        XCTAssertEqual(mTheme.cellHeight, 22)
    }

    // MARK: - Renderer Configuration and Static Helpers

    func testRendererInitAndPixelSize() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        var renderer = TerminalRenderer(
            metrics: metrics,
            defaultForeground: srgb(r: 200, g: 200, b: 200),
            defaultBackground: srgb(r: 20, g: 20, b: 20),
            selectionColor: srgb(1, 0, 0, 0.5),
            cursorColor: srgb(r: 255, g: 100, b: 50)
        )
        XCTAssertFalse(renderer.unfocused)
        renderer.unfocused = true
        XCTAssertTrue(renderer.unfocused)

        let size = renderer.pixelSize(cols: 80, rows: 24)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 480)
    }

    func testStaticStringForScalar() {
        // ASCII fast path (table lookup)
        XCTAssertEqual(TerminalRenderer.string(for: 65), "A")
        XCTAssertEqual(TerminalRenderer.string(for: 32), " ")
        XCTAssertEqual(TerminalRenderer.string(for: 0), "\0")

        // Unicode scalar >= 128
        XCTAssertEqual(TerminalRenderer.string(for: 0x4E2D), "中")
        XCTAssertEqual(TerminalRenderer.string(for: 0x2500), "─")

        // Invalid unicode scalar fallback (e.g. UTF-16 surrogate)
        XCTAssertEqual(TerminalRenderer.string(for: 0xD800), " ")
    }

    // MARK: - Background Runs

    func testBackgroundRuns() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo")
        let bgDefault = srgb(r: 0x14, g: 0x10, b: 0x0e)
        let renderer = TerminalRenderer(metrics: metrics, defaultBackground: bgDefault)

        // Empty cells
        XCTAssertTrue(renderer.backgroundRuns(for: []).isEmpty)

        // Cells all default background (filtered out)
        let defaultCells = [
            makeCell(bg: (0x14, 0x10, 0x0e)),
            makeCell(bg: (0x14, 0x10, 0x0e)),
        ]
        XCTAssertTrue(renderer.backgroundRuns(for: defaultCells).isEmpty)

        // Custom backgrounds: 2 red, 1 green, 1 default
        let customCells = [
            makeCell(bg: (255, 0, 0)),
            makeCell(bg: (255, 0, 0)),
            makeCell(bg: (0, 255, 0)),
            makeCell(bg: (0x14, 0x10, 0x0e)),
        ]
        let runs = renderer.backgroundRuns(for: customCells)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].range, 0..<2)
        XCTAssertEqual(runs[1].range, 2..<3)

        // Reverse video swaps foreground into background
        let reverseCells = [
            makeCell(fg: (0, 0, 255), bg: (0x14, 0x10, 0x0e), reverse: true),
        ]
        let reverseRuns = renderer.backgroundRuns(for: reverseCells)
        XCTAssertEqual(reverseRuns.count, 1)
        XCTAssertEqual(reverseRuns[0].range, 0..<1)
    }

    // MARK: - Viewport Drawing

    func testDrawViewportWithBackgroundAndSkipBackground() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let renderer = TerminalRenderer(
            metrics: metrics,
            defaultForeground: srgb(r: 255, g: 255, b: 255),
            defaultBackground: srgb(r: 100, g: 50, b: 25)
        )

        let bitmap1 = BitmapContext(width: 40, height: 40)
        renderer.draw(
            in: bitmap1.context,
            cols: 4,
            rows: 2,
            rowProvider: { _ in [self.makeCell(ch: " ")] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: false,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            selection: nil,
            skipBackgrounds: false
        )
        // Background should be filled with defaultBackground, in colour too.
        // (rowProvider only supplies a single cell per row, at col 0, whose
        // own default-black background paints over col 0 -- sample col 2,
        // which only the full-viewport fill ever touches.)
        let p1 = bitmap1.pixel(atX: 5, y: 5)
        XCTAssertGreaterThan(p1.a, 0)
        assertColorApprox(bitmap1.pixel(atX: 25, y: 5), (100, 50, 25))

        // Skip backgrounds should not fill background
        let bitmap2 = BitmapContext(width: 40, height: 40)
        renderer.draw(
            in: bitmap2.context,
            cols: 4,
            rows: 2,
            rowProvider: { _ in [self.makeCell(ch: " ")] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: false,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            selection: nil,
            skipBackgrounds: true
        )
        let p2 = bitmap2.pixel(atX: 5, y: 5)
        XCTAssertEqual(p2.a, 0)
    }

    // MARK: - Cursor Drawing

    func testDrawCursorShapesAndFocus() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        var renderer = TerminalRenderer(
            metrics: metrics,
            cursorColor: srgb(r: 255, g: 0, b: 0)
        )

        // 1. Block cursor focused: fills the whole cell.
        let b1 = BitmapContext(width: 20, height: 20)
        renderer.draw(
            in: b1.context,
            cols: 2,
            rows: 1,
            rowProvider: { _ in [] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: true,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            skipBackgrounds: true
        )
        let b1Center = b1.pixel(atX: 5, logicalY: 10)
        XCTAssertGreaterThan(b1Center.a, 0)
        assertColorApprox(b1Center, (255, 0, 0))
        // Only the cursor's own cell (col 0) is painted, not the neighbour.
        XCTAssertEqual(b1.pixel(atX: 15, logicalY: 10).a, 0)

        // 2. Block cursor unfocused: an outline, not a fill -- the centre of
        // the cell stays empty while the filled version's centre did not.
        renderer.unfocused = true
        let b2 = BitmapContext(width: 20, height: 20)
        renderer.draw(
            in: b2.context,
            cols: 2,
            rows: 1,
            rowProvider: { _ in [] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: true,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            skipBackgrounds: true
        )
        XCTAssertEqual(b2.pixel(atX: 5, logicalY: 10).a, 0)
        XCTAssertGreaterThan(b2.pixel(atX: 0, logicalY: 10).a, 0)

        // 3. Underline cursor: a thin band at the bottom of the cell, not
        // the middle -- distinct from both the block and the bar.
        renderer.unfocused = false
        let b3 = BitmapContext(width: 20, height: 20)
        renderer.draw(
            in: b3.context,
            cols: 2,
            rows: 1,
            rowProvider: { _ in [] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: true,
            cursorStyle: FfiCursorStyle(shape: .underline, blinking: false),
            skipBackgrounds: true
        )
        let b3Bottom = b3.pixel(atX: 5, logicalY: 0)
        XCTAssertGreaterThan(b3Bottom.a, 0)
        assertColorApprox(b3Bottom, (255, 0, 0))
        XCTAssertEqual(b3.pixel(atX: 1, logicalY: 10).a, 0)
        XCTAssertEqual(b3.pixel(atX: 5, logicalY: 19).a, 0)

        // 4. Bar cursor: a thin column at the left of the cell, full height
        // -- opaque where the underline was empty, and empty where the
        // underline's band was opaque.
        let b4 = BitmapContext(width: 20, height: 20)
        renderer.draw(
            in: b4.context,
            cols: 2,
            rows: 1,
            rowProvider: { _ in [] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: true,
            cursorStyle: FfiCursorStyle(shape: .bar, blinking: false),
            skipBackgrounds: true
        )
        XCTAssertGreaterThan(b4.pixel(atX: 1, logicalY: 10).a, 0)
        XCTAssertEqual(b4.pixel(atX: 5, logicalY: 0).a, 0)
        XCTAssertEqual(b4.pixel(atX: 5, logicalY: 10).a, 0)

        // 5. Cursor invisible: nothing drawn anywhere in its cell.
        let b5 = BitmapContext(width: 20, height: 20)
        renderer.draw(
            in: b5.context,
            cols: 2,
            rows: 1,
            rowProvider: { _ in [] },
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: false,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            skipBackgrounds: true
        )
        XCTAssertEqual(b5.nonZeroCount(xRange: 0..<10, yRange: 0..<20), 0)
    }


}
