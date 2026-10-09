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
    // MARK: - Kitty Graphics Placements and Images

    func testDrawImages() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let renderer = TerminalRenderer(metrics: metrics)
        // Placement at row 0, col 0 with a 2x2 image lands at logical
        // x in [0, 2), y in [38, 40) for this cellWidth/cellHeight/rows.
        let insideX = 0
        let insideY = 39
        let outsideX = 20
        let outsideY = 10

        // Empty placements: nothing drawn at the would-be image location.
        let b0 = BitmapContext(width: 40, height: 40)
        renderer.drawImages([], rows: 2, imageProvider: { _ in nil }, in: b0.context)
        XCTAssertEqual(b0.pixel(atX: insideX, logicalY: insideY).a, 0)

        // Provider returning nil (missing image): same, nothing drawn.
        let b1 = BitmapContext(width: 40, height: 40)
        let placement1 = FfiGraphicsPlacement(imageId: 99, placementId: 1, row: 0, col: 0)
        renderer.drawImages([placement1], rows: 2, imageProvider: { _ in nil }, in: b1.context)
        XCTAssertEqual(b1.pixel(atX: insideX, logicalY: insideY).a, 0)

        // Valid PNG image: the placement's bounds contain the image's
        // colour, and a point outside those bounds stays background.
        let pngData = makeTestPNGData()
        XCTAssertFalse(pngData.isEmpty)
        let pngImage = FfiStoredImage(format: .png, width: 2, height: 2, pixels: pngData)
        let b2 = BitmapContext(width: 40, height: 40)
        let placement2 = FfiGraphicsPlacement(imageId: 1, placementId: 1, row: 0, col: 0)
        renderer.drawImages([placement2], rows: 2, imageProvider: { id in
            id == 1 ? pngImage : nil
        }, in: b2.context)
        let pngPixel = b2.pixel(atX: insideX, logicalY: insideY)
        XCTAssertGreaterThan(pngPixel.a, 0)
        assertColorApprox(pngPixel, (255, 0, 0))
        XCTAssertEqual(b2.pixel(atX: outsideX, logicalY: outsideY).a, 0)

        // Corrupt PNG image: decode fails, nothing drawn at the placement.
        let corruptPng = FfiStoredImage(format: .png, width: 2, height: 2, pixels: Data([1, 2, 3, 4]))
        let b3 = BitmapContext(width: 40, height: 40)
        renderer.drawImages([placement2], rows: 2, imageProvider: { _ in corruptPng }, in: b3.context)
        XCTAssertEqual(b3.pixel(atX: insideX, logicalY: insideY).a, 0)

        // Valid RGB image (2x2 RGB = 12 bytes): placement bounds show the
        // image colour; outside stays background.
        let rgbBytes = [UInt8](repeating: 255, count: 12)
        let rgbImage = FfiStoredImage(format: .rgb, width: 2, height: 2, pixels: Data(rgbBytes))
        let b4 = BitmapContext(width: 40, height: 40)
        renderer.drawImages([placement2], rows: 2, imageProvider: { _ in rgbImage }, in: b4.context)
        let rgbPixel = b4.pixel(atX: insideX, logicalY: insideY)
        XCTAssertGreaterThan(rgbPixel.a, 0)
        assertColorApprox(rgbPixel, (255, 255, 255))
        XCTAssertEqual(b4.pixel(atX: outsideX, logicalY: outsideY).a, 0)

        // Truncated RGB image (fewer bytes than width * height * 3): nothing drawn.
        let truncatedRgb = FfiStoredImage(format: .rgb, width: 2, height: 2, pixels: Data([255, 255]))
        let b5 = BitmapContext(width: 40, height: 40)
        renderer.drawImages([placement2], rows: 2, imageProvider: { _ in truncatedRgb }, in: b5.context)
        XCTAssertEqual(b5.pixel(atX: insideX, logicalY: insideY).a, 0)

        // Zero dimension RGB image: nothing drawn.
        let zeroDimRgb = FfiStoredImage(format: .rgb, width: 0, height: 2, pixels: Data())
        let b6 = BitmapContext(width: 40, height: 40)
        renderer.drawImages([placement2], rows: 2, imageProvider: { _ in zeroDimRgb }, in: b6.context)
        XCTAssertEqual(b6.pixel(atX: insideX, logicalY: insideY).a, 0)

        // Valid RGBA image (2x2 RGBA = 16 bytes): placement bounds show the
        // image colour.
        let rgbaBytes = [UInt8](repeating: 255, count: 16)
        let rgbaImage = FfiStoredImage(format: .rgba, width: 2, height: 2, pixels: Data(rgbaBytes))
        let b7 = BitmapContext(width: 40, height: 40)
        renderer.drawImages([placement2], rows: 2, imageProvider: { _ in rgbaImage }, in: b7.context)
        let rgbaPixel = b7.pixel(atX: insideX, logicalY: insideY)
        XCTAssertGreaterThan(rgbaPixel.a, 0)
        assertColorApprox(rgbaPixel, (255, 255, 255))
    }

    // MARK: - selection-foreground / selection-invert-fg-bg

    func testSelectionForegroundOverridesSelectedTextColorOnly() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        var renderer = TerminalRenderer(metrics: metrics)
        renderer.selectionForeground = srgb(r: 255, g: 0, b: 0)

        let cells = [makeCell(ch: "█", fg: (0, 0, 255))]

        // Not selected: the cell's own foreground.
        let unselected = BitmapContext(width: 10, height: 20)
        renderer.drawRow(cells, row: 0, rows: 1, in: unselected.context, skipBackground: true)
        assertColorApprox(unselected.pixel(atX: 5, logicalY: 10), (0, 0, 255))

        // Selected: `selectionForeground`, not the cell's own foreground.
        let selected = BitmapContext(width: 10, height: 20)
        renderer.drawRow(cells, row: 0, rows: 1, in: selected.context, skipBackground: true, selectedColumns: 0...0)
        assertColorApprox(selected.pixel(atX: 5, logicalY: 10), (255, 0, 0))
    }

    func testSelectionInvertFgBgSwapsSelectedCellColorsAndSkipsTheOverlay() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        var renderer = TerminalRenderer(metrics: metrics, defaultBackground: srgb(r: 10, g: 10, b: 10))
        renderer.selectionInvertFgBg = true
        // A loud, easy-to-spot overlay color: if this ever shows up in the
        // selected cell, the plain overlay path ran instead of the swap.
        renderer.selectionColor = srgb(r: 0, g: 255, b: 255)

        // Column 0: a blank cell, so its swapped background fill can be
        // sampled without any glyph ink on top. Column 1: a full-block
        // glyph, so its swapped ink color can be sampled the same way
        // `testSelectionForegroundOverridesSelectedTextColorOnly` does.
        let cells = [
            makeCell(ch: " ", fg: (0, 0, 255), bg: (0, 255, 0)),
            makeCell(ch: "█", fg: (0, 0, 255), bg: (0, 255, 0)),
        ]
        let selection = FfiSelectionRange(startRow: 0, startCol: 0, endRow: 0, endCol: 1, mode: .linear)

        let ctx = BitmapContext(width: 20, height: 20)
        renderer.draw(
            in: ctx.context, cols: 2, rows: 1,
            rowProvider: { _ in cells },
            cursorRow: 0, cursorCol: 0, cursorVisible: false,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
            selection: selection
        )
        // The blank cell's background quad now carries its own foreground,
        // and the glyph's ink now carries the cell's own (resolved)
        // background -- the overlay cyan appears nowhere.
        assertColorApprox(ctx.pixel(atX: 5, logicalY: 10), (0, 0, 255))
        assertColorApprox(ctx.pixel(atX: 15, logicalY: 10), (0, 255, 0))
    }

    // MARK: - cursor-opacity / cursor-thickness

    func testCursorOpacityScalesTheCursorsAlpha() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        func render(opacity: Double) -> BitmapContext {
            let renderer = TerminalRenderer(
                metrics: metrics, cursorColor: srgb(r: 255, g: 0, b: 0), cursorOpacity: opacity
            )
            let ctx = BitmapContext(width: 10, height: 20)
            renderer.draw(
                in: ctx.context, cols: 1, rows: 1, rowProvider: { _ in [] },
                cursorRow: 0, cursorCol: 0, cursorVisible: true,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
                skipBackgrounds: true
            )
            return ctx
        }
        let full = render(opacity: 1.0)
        let half = render(opacity: 0.5)
        let fullPixel = full.pixel(atX: 5, logicalY: 10)
        let halfPixel = half.pixel(atX: 5, logicalY: 10)
        XCTAssertEqual(fullPixel.a, 255)
        XCTAssertTrue(approx(halfPixel.a, 128, tolerance: 5), "expected ~half alpha, got \(halfPixel.a)")
        // Premultiplied storage: the stored red channel halves along with alpha.
        XCTAssertLessThan(halfPixel.r, fullPixel.r)
    }

    func testCursorThicknessWidensBarAndUnderlineCursors() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        func render(shape: FfiCursorShape, thickness: CGFloat?) -> BitmapContext {
            let renderer = TerminalRenderer(
                metrics: metrics, cursorColor: srgb(r: 255, g: 0, b: 0), cursorThickness: thickness
            )
            let ctx = BitmapContext(width: 10, height: 20)
            renderer.draw(
                in: ctx.context, cols: 1, rows: 1, rowProvider: { _ in [] },
                cursorRow: 0, cursorCol: 0, cursorVisible: true,
                cursorStyle: FfiCursorStyle(shape: shape, blinking: false),
                skipBackgrounds: true
            )
            return ctx
        }

        // Bar: the default (nil, 2pt) leaves x=5 untouched; 6pt reaches it.
        let barDefault = render(shape: .bar, thickness: nil)
        let barThick = render(shape: .bar, thickness: 6)
        XCTAssertEqual(barDefault.pixel(atX: 5, logicalY: 10).a, 0)
        XCTAssertGreaterThan(barThick.pixel(atX: 5, logicalY: 10).a, 0)

        // Underline: the default band is 2px tall; 6pt reaches y=4.
        let underlineDefault = render(shape: .underline, thickness: nil)
        let underlineThick = render(shape: .underline, thickness: 6)
        XCTAssertEqual(underlineDefault.pixel(atX: 5, logicalY: 4).a, 0)
        XCTAssertGreaterThan(underlineThick.pixel(atX: 5, logicalY: 4).a, 0)
    }

    // MARK: - window-padding-balance

    func testWindowPaddingBalanceSpreadsTheLeftoverOnAllSides() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let renderer = TerminalRenderer(metrics: metrics)
        // 2 cols x 1 row = 20x20 grid, in a 30x26 window with 2pt padding:
        // 6pt of horizontal slack and 2pt of vertical slack to distribute.
        let windowSize = CGSize(width: 30, height: 26)
        let cell = CGSize(width: 10, height: 20)
        let padding = TerminalPadding(uniform: 2)

        let unbalanced = TerminalGridLayout(viewSize: windowSize, cellSize: cell, padding: padding, balance: false)
        XCTAssertEqual([unbalanced.cols, unbalanced.rows], [2, 1])
        XCTAssertEqual([unbalanced.left, unbalanced.top], [2, 2])
        XCTAssertEqual([unbalanced.right(in: windowSize), unbalanced.bottom(in: windowSize)], [8, 4])

        let balanced = TerminalGridLayout(viewSize: windowSize, cellSize: cell, padding: padding, balance: true)
        XCTAssertEqual([balanced.left, balanced.top], [5, 3])
        XCTAssertEqual([balanced.right(in: windowSize), balanced.bottom(in: windowSize)], [5, 3])

        // A rendered pixel: at x=3 the unbalanced grid has already started
        // (left inset 2) but the balanced grid has not (left inset 5), so
        // this column tells the two apart the way a user's eye would.
        func renderAt(_ layout: TerminalGridLayout) -> BitmapContext {
            let ctx = BitmapContext(width: 30, height: 26)
            // `drawWindow` assumes the caller already cleared the window to
            // its own background, exactly as the production draw path does.
            ctx.context.setFillColor(renderer.defaultBackground)
            ctx.context.fill(CGRect(origin: .zero, size: windowSize))
            renderer.drawWindow(
                in: ctx.context, windowSize: windowSize, layout: layout, paddingColor: .background,
                cols: 2, rows: 1,
                rowProvider: { _ in [self.makeCell(bg: (0, 255, 0)), self.makeCell(bg: (0, 255, 0))] },
                cursorRow: 0, cursorCol: 0, cursorVisible: false,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false)
            )
            return ctx
        }
        assertColorApprox(renderAt(unbalanced).pixel(atX: 3, logicalY: 13), (0, 255, 0))
        assertColorApprox(renderAt(balanced).pixel(atX: 3, logicalY: 13), (0x14, 0x10, 0x0e))
        // The grid starts below the top padding, not at the view's edge
        // (logical y counts up from the bottom: the top margin is 24..<26).
        assertColorApprox(renderAt(unbalanced).pixel(atX: 5, logicalY: 25), (0x14, 0x10, 0x0e))
        assertColorApprox(renderAt(unbalanced).pixel(atX: 5, logicalY: 23), (0, 255, 0))
    }

    // MARK: - window-padding-color

    func testWindowPaddingColorExtendsTheEdgeCells() {
        let metrics = TerminalRenderer.Metrics(fontSize: 13, fontName: "Menlo", cellWidth: 10, cellHeight: 20)
        let defaultBg = srgb(r: 0x14, g: 0x10, b: 0x0e)
        let renderer = TerminalRenderer(metrics: metrics, defaultBackground: defaultBg)
        // One row of two cells in a 24x28 view with 2pt padding: margins on
        // every side, 2pt right, 4pt top and bottom.
        let windowSize = CGSize(width: 24, height: 28)
        let red: (UInt8, UInt8, UInt8) = (200, 0, 0)
        let layout = TerminalGridLayout(
            viewSize: windowSize, cellSize: CGSize(width: 10, height: 20),
            padding: TerminalPadding(left: 2, right: 2, top: 4, bottom: 4), balance: false
        )

        func render(_ paddingColor: TerminalTheme.WindowPaddingColor, row: [TerminalCell]) -> BitmapContext {
            let ctx = BitmapContext(width: 24, height: 28)
            ctx.context.setFillColor(defaultBg)
            ctx.context.fill(CGRect(origin: .zero, size: windowSize))
            renderer.drawWindow(
                in: ctx.context, windowSize: windowSize, layout: layout, paddingColor: paddingColor,
                cols: 2, rows: 1, rowProvider: { _ in row },
                cursorRow: 0, cursorCol: 0, cursorVisible: false,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false)
            )
            return ctx
        }
        let colored = [makeCell(bg: red), makeCell(bg: red)]
        // One cell on the default background: a prompt-like row.
        let mixed = [makeCell(bg: red), makeCell(bg: (0x14, 0x10, 0x0e))]
        // Logical y counts up from the bottom: the top margin is 24..<28.
        let right = (x: 23, y: 14), top = (x: 5, y: 26)

        // background: the margins keep the view's own background.
        assertColorApprox(render(.background, row: colored).pixel(atX: right.x, logicalY: right.y), (0x14, 0x10, 0x0e))
        assertColorApprox(render(.background, row: colored).pixel(atX: 0, logicalY: 14), (0x14, 0x10, 0x0e))

        // extend: the sides always take the edge cells; above and below only
        // when the edge row has no default-background cell.
        assertColorApprox(render(.extend, row: colored).pixel(atX: 0, logicalY: 14), red)
        assertColorApprox(render(.extend, row: colored).pixel(atX: top.x, logicalY: top.y), red)
        assertColorApprox(render(.extend, row: mixed).pixel(atX: 0, logicalY: 14), red)
        assertColorApprox(render(.extend, row: mixed).pixel(atX: top.x, logicalY: top.y), (0x14, 0x10, 0x0e))
        // A default-background edge cell leaves its margin to the view.
        assertColorApprox(render(.extend, row: mixed).pixel(atX: right.x, logicalY: right.y), (0x14, 0x10, 0x0e))

        // extend-always: above and below regardless.
        assertColorApprox(render(.extendAlways, row: mixed).pixel(atX: top.x, logicalY: top.y), red)
    }
}
