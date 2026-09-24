import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import TakoCoreUI

final class TerminalRendererCoverageTests: XCTestCase {

    // MARK: - Helpers

    private final class BitmapContext {
        let width: Int
        let height: Int
        let context: CGContext
        let data: UnsafeMutablePointer<UInt8>

        init(width: Int, height: Int) {
            self.width = max(1, width)
            self.height = max(1, height)
            let bytesPerRow = self.width * 4
            self.data = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * self.height)
            self.data.initialize(repeating: 0, count: bytesPerRow * self.height)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            self.context = CGContext(
                data: self.data,
                width: self.width,
                height: self.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }

        deinit {
            data.deallocate()
        }

        /// Sample a pixel using the buffer's own memory-row addressing
        /// (row 0 is the top of the image).
        func pixel(atX x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else { return (0, 0, 0, 0) }
            let offset = (y * width + x) * 4
            return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
        }

        /// Sample a pixel using CoreGraphics' own logical coordinate space
        /// (origin bottom-left, y increasing upward) -- the same space every
        /// drawing formula in `TerminalRenderer` computes in. This is what
        /// lets a test reproduce the renderer's own math instead of guessing
        /// at memory layout.
        func pixel(atX x: Int, logicalY: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            pixel(atX: x, y: height - 1 - logicalY)
        }

        /// Count of pixels with any non-zero channel within a memory-space
        /// sub-region, so a check can be scoped to the exact area a feature
        /// owns instead of the whole canvas.
        func nonZeroCount(xRange: Range<Int>, yRange: Range<Int>) -> Int {
            var count = 0
            for y in yRange {
                for x in xRange {
                    let p = pixel(atX: x, y: y)
                    if p.r != 0 || p.g != 0 || p.b != 0 || p.a != 0 { count += 1 }
                }
            }
            return count
        }
    }

    /// Count of pixels that differ between two same-sized renders -- the
    /// building block for "render the cell with and without the attribute
    /// and assert the region actually changed" checks.
    private func differingPixelCount(_ a: BitmapContext, _ b: BitmapContext) -> Int {
        guard a.width == b.width, a.height == b.height else {
            return max(a.width * a.height, b.width * b.height)
        }
        var count = 0
        for i in 0..<(a.width * a.height) {
            let o = i * 4
            if a.data[o] != b.data[o] || a.data[o + 1] != b.data[o + 1]
                || a.data[o + 2] != b.data[o + 2] || a.data[o + 3] != b.data[o + 3] {
                count += 1
            }
        }
        return count
    }

    private func isInk(_ ctx: BitmapContext, x: Int, logicalY: Int) -> Bool {
        ctx.pixel(atX: x, logicalY: logicalY).a != 0
    }

    private func inkCount(_ ctx: BitmapContext, xRange: Range<Int>, logicalYRange: Range<Int>) -> Int {
        var count = 0
        for y in logicalYRange {
            for x in xRange {
                if ctx.pixel(atX: x, logicalY: y).a != 0 { count += 1 }
            }
        }
        return count
    }

    /// Number of distinct rows within `logicalYRange` that carry any ink in
    /// `xRange` -- a glyph's vertical extent, without assuming exactly
    /// where in the cell that extent sits.
    private func inkRowSpan(_ ctx: BitmapContext, xRange: Range<Int>, logicalYRange: Range<Int>) -> Int {
        logicalYRange.reduce(0) { count, y in
            count + (xRange.contains { ctx.pixel(atX: $0, logicalY: y).a != 0 } ? 1 : 0)
        }
    }

    private func approx(_ a: UInt8, _ b: UInt8, tolerance: Int = 20) -> Bool {
        abs(Int(a) - Int(b)) <= tolerance
    }

    private func assertColorApprox(
        _ pixel: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
        _ expected: (UInt8, UInt8, UInt8),
        tolerance: Int = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            approx(pixel.r, expected.0, tolerance: tolerance)
                && approx(pixel.g, expected.1, tolerance: tolerance)
                && approx(pixel.b, expected.2, tolerance: tolerance),
            "pixel (\(pixel.r), \(pixel.g), \(pixel.b)) not within \(tolerance) of \(expected)",
            file: file, line: line
        )
    }

    private func makeCell(
        ch: Character = " ",
        fg: (UInt8, UInt8, UInt8) = (255, 255, 255),
        bg: (UInt8, UInt8, UInt8) = (0, 0, 0),
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        blink: Bool = false,
        reverse: Bool = false,
        hidden: Bool = false,
        strikethrough: Bool = false,
        overline: Bool = false,
        underlineStyle: UInt8 = 0,
        ul: (UInt8, UInt8, UInt8) = (255, 255, 255),
        wide: Bool = false
    ) -> TerminalCell {
        let scalar = ch.unicodeScalars.first?.value ?? 32
        let ffi = FfiCell(
            ch: scalar,
            fgR: fg.0, fgG: fg.1, fgB: fg.2,
            bgR: bg.0, bgG: bg.1, bgB: bg.2,
            bold: bold,
            dim: dim,
            italic: italic,
            underline: underline,
            blink: blink,
            reverse: reverse,
            hidden: hidden,
            strikethrough: strikethrough,
            overline: overline,
            underlineStyle: underlineStyle,
            ulR: ul.0,
            ulG: ul.1,
            ulB: ul.2,
            hyperlinkUri: nil,
            wide: wide
        )
        return TerminalCell(ffi)
    }

    private func makeCellWithScalar(
        scalar: UInt32,
        fg: (UInt8, UInt8, UInt8) = (255, 255, 255),
        bg: (UInt8, UInt8, UInt8) = (0, 0, 0),
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        blink: Bool = false,
        reverse: Bool = false,
        hidden: Bool = false,
        strikethrough: Bool = false,
        overline: Bool = false,
        underlineStyle: UInt8 = 0,
        ul: (UInt8, UInt8, UInt8) = (255, 255, 255),
        wide: Bool = false
    ) -> TerminalCell {
        let ffi = FfiCell(
            ch: scalar,
            fgR: fg.0, fgG: fg.1, fgB: fg.2,
            bgR: bg.0, bgG: bg.1, bgB: bg.2,
            bold: bold,
            dim: dim,
            italic: italic,
            underline: underline,
            blink: blink,
            reverse: reverse,
            hidden: hidden,
            strikethrough: strikethrough,
            overline: overline,
            underlineStyle: underlineStyle,
            ulR: ul.0,
            ulG: ul.1,
            ulB: ul.2,
            hyperlinkUri: nil,
            wide: wide
        )
        return TerminalCell(ffi)
    }

    private func makeTestPNGData() -> Data {
        let width = 2
        let height = 2
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

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
