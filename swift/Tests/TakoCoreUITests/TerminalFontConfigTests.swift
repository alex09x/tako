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
import Foundation
import XCTest
@testable import TakoCoreUI

/// The font keys a config sets -- styled families and faces, synthesis,
/// OpenType features and the metric adjustments -- as the renderers draw
/// them. Each key is set through `TerminalTheme.parse` and checked by what
/// reaches the screen: the face a cell is drawn with, its pixels, or the
/// geometry of the grid.
final class TerminalFontConfigTests: XCTestCase {

    // MARK: - Fixtures

    struct Cell {
        var ch: UInt32
        var bits: UInt16 = 0
        var underlineStyle: UInt8 = 0

        static let bold: UInt16 = 1 << 0
        static let italic: UInt16 = 1 << 2
        static let underline: UInt16 = 1 << 3
    }

    private func packed(_ cells: [Cell]) -> Data {
        var bytes = [UInt8]()
        for cell in cells {
            bytes += withUnsafeBytes(of: cell.ch.littleEndian, Array.init)
            bytes += [0, 255, 0]          // green text
            bytes += [0, 0, 0]            // on black
            bytes += [UInt8(truncatingIfNeeded: cell.bits), UInt8(truncatingIfNeeded: cell.bits >> 8)]
            bytes += [cell.underlineStyle, 255, 0, 0]  // red underline
        }
        return Data(bytes)
    }

    private func terminalCells(_ cells: [Cell]) -> [TerminalCell] {
        let data = packed(cells)
        return data.withUnsafeBytes { raw in
            (0..<cells.count).map { TerminalCell(raw, $0 * TerminalCell.byteSize) }
        }
    }

    private func frame(_ cells: [Cell]) -> FfiRenderFrame {
        FfiRenderFrame(
            snapshot: FfiSnapshot(
                cols: UInt32(cells.count),
                rows: 1,
                cursorRow: 0,
                cursorCol: 0,
                cursorVisible: false,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
                title: "",
                modes: FfiTerminalModes(
                    autowrap: true, originMode: false, cursorKeyAppMode: false, mouseTracking: .off,
                    mouseUtf8: false, mouseSgr: false, focusEvents: false, bracketedPaste: false,
                    alternateScreen: false, alternateScroll: false),
                viewportOffset: 0,
                scrollbackLen: 0,
                damagedRows: [0],
                selection: nil,
                graphicsPlacements: []
            ),
            packedCells: packed(cells),
            epoch: 0
        )
    }

    private func metrics(_ config: String) -> TerminalRenderer.Metrics {
        TerminalRenderer.Metrics(theme: TerminalTheme.parse(config: config, honourTheme: false))
    }

    func planner(_ config: String, _ cells: [Cell]) -> TerminalMetalFramePlanner {
        let planner = TerminalMetalFramePlanner(metrics: TerminalMetalCellMetrics(metrics(config), scale: 1))
        planner.plan(frame: frame(cells), viewport: TerminalMetalViewport(drawableWidth: 400, drawableHeight: 200))
        return planner
    }

    /// The atlas mask the GPU draws for one cell, and where it lands.
    struct PlannedGlyph: Equatable {
        let mask: [UInt8]
        let width: Int
        let height: Int
        let top: Float
        var ink: Int { mask.reduce(0) { $0 + Int($1) } }
    }

    func plannedGlyph(_ config: String, _ cell: Cell) throws -> PlannedGlyph {
        let planner = planner(config, [cell])
        let instance = try XCTUnwrap(planner.glyphInstances.first, "no glyph planned")
        let page = planner.atlas.pages[Int(instance.atlasPage)]
        let x0 = Int((instance.uvRect.x * Float(page.width)).rounded())
        let y0 = Int((instance.uvRect.y * Float(page.height)).rounded())
        let width = Int(instance.destRect.z)
        let height = Int(instance.destRect.w)
        var mask = [UInt8]()
        for row in y0..<(y0 + height) {
            let start = row * page.bytesPerRow + x0
            mask += page.data[start..<(start + width)]
        }
        return PlannedGlyph(mask: mask, width: width, height: height, top: instance.destRect.y)
    }

    /// One row drawn by the CoreGraphics renderer: RGBA bytes, top row first.
    struct Bitmap: Equatable {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2])
        }

        /// Rows holding the red underline.
        var underlineRows: [Int] {
            (0..<height).filter { y in
                (0..<width).contains { x in let p = pixel(x: x, y: y); return p.r > 200 && p.g < 60 }
            }
        }

        /// Rows holding any green text.
        var inkRows: [Int] {
            (0..<height).filter { y in (0..<width).contains { x in pixel(x: x, y: y).g > 60 } }
        }

        var ink: Int { stride(from: 1, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) } }
    }

    func drawn(_ config: String, _ cells: [Cell]) -> Bitmap {
        let renderer = TerminalRenderer(
            metrics: metrics(config),
            defaultForeground: srgb(0, 1, 0, 1),
            defaultBackground: srgb(0, 0, 0, 1)
        )
        let size = renderer.pixelSize(cols: cells.count, rows: 1)
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let row = terminalCells(cells)
            renderer.draw(
                in: context, cols: cells.count, rows: 1, rowProvider: { _ in row },
                cursorRow: 0, cursorCol: 0, cursorVisible: false,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false))
        }
        return Bitmap(pixels: pixels, width: width, height: height)
    }

    private func name(_ font: CTFont) -> String { CTFontCopyPostScriptName(font) as String }

    private func requireFamily(_ family: String) throws {
        let font = CTFontCreateWithName(family as CFString, 13, nil)
        guard CTFontCopyFamilyName(font) as String == family else {
            throw XCTSkip("\(family) is not installed here")
        }
    }

    // MARK: - font-family-bold, -italic, -bold-italic

    func testBoldFamilyDrawsBoldCellsInThatFamily() throws {
        try requireFamily("Courier New")
        let base = "font-family = Menlo\n"
        let bold = Cell(ch: 0x41, bits: Cell.bold)

        XCTAssertEqual(name(metrics(base + "font-family-bold = Courier New").boldFont), "CourierNewPS-BoldMT")
        XCTAssertEqual(planner(base + "font-family-bold = Courier New", [bold]).resolvedFontName(for: 0x41, bold: true),
                       "CourierNewPS-BoldMT")
        XCTAssertNotEqual(try plannedGlyph(base + "font-family-bold = Courier New", bold), try plannedGlyph(base, bold))
        XCTAssertNotEqual(drawn(base + "font-family-bold = Courier New", [bold]), drawn(base, [bold]))
        // Regular text keeps font-family.
        XCTAssertEqual(name(metrics(base + "font-family-bold = Courier New").font), "Menlo-Regular")

        // A family that is not installed falls back to font-family's bold.
        XCTAssertEqual(name(metrics(base + "font-family-bold = No Such Family Here").boldFont), "Menlo-Bold")
        XCTAssertEqual(drawn(base + "font-family-bold = No Such Family Here", [bold]), drawn(base, [bold]))
    }

    func testItalicFamilyDrawsItalicCellsInThatFamily() throws {
        try requireFamily("Courier New")
        let base = "font-family = Menlo\n"
        let italic = Cell(ch: 0x41, bits: Cell.italic)

        XCTAssertEqual(name(metrics(base + "font-family-italic = \"Courier New\"").italicFont), "CourierNewPS-ItalicMT")
        XCTAssertNotEqual(try plannedGlyph(base + "font-family-italic = Courier New", italic),
                          try plannedGlyph(base, italic))
        XCTAssertNotEqual(drawn(base + "font-family-italic = Courier New", [italic]), drawn(base, [italic]))

        XCTAssertEqual(name(metrics(base + "font-family-italic = No Such Family Here").italicFont), "Menlo-Italic")
        XCTAssertEqual(name(metrics(base + "font-family-italic = Courier New\nfont-family-italic =").italicFont),
                       "Menlo-Italic", "an empty value returns to font-family")
    }

    func testBoldItalicFamilyDrawsBoldItalicCellsInThatFamily() throws {
        try requireFamily("Courier New")
        let base = "font-family = Menlo\n"
        let both = Cell(ch: 0x41, bits: Cell.bold | Cell.italic)

        XCTAssertEqual(name(metrics(base + "font-family-bold-italic = Courier New").boldItalicFont),
                       "CourierNewPS-BoldItalicMT")
        XCTAssertNotEqual(try plannedGlyph(base + "font-family-bold-italic = Courier New", both),
                          try plannedGlyph(base, both))
        // Only the bold-italic style moves.
        XCTAssertEqual(name(metrics(base + "font-family-bold-italic = Courier New").boldFont), "Menlo-Bold")

        XCTAssertEqual(name(metrics(base + "font-family-bold-italic = No Such Family Here").boldItalicFont),
                       "Menlo-BoldItalic")
    }

    // MARK: - font-style

    func testFontStyleNamesTheRegularFace() throws {
        try requireFamily("Helvetica Neue")
        let base = "font-family = Helvetica Neue\n"
        let plain = Cell(ch: 0x41)

        XCTAssertEqual(name(metrics(base + "font-style = Light").font), "HelveticaNeue-Light")
        XCTAssertLessThan(try plannedGlyph(base + "font-style = Light", plain).ink, try plannedGlyph(base, plain).ink,
                          "a light face puts less ink down")
        XCTAssertNotEqual(drawn(base + "font-style = Light", [plain]), drawn(base, [plain]))

        XCTAssertEqual(name(metrics(base + "font-style = Extra Wobbly").font), "HelveticaNeue")
        XCTAssertEqual(drawn(base + "font-style = Extra Wobbly", [plain]), drawn(base, [plain]))
        XCTAssertEqual(name(metrics(base + "font-style = false").font), "HelveticaNeue")
    }

    func testBoldStyleNamesTheBoldFaceOrDisablesBold() throws {
        try requireFamily("Helvetica Neue")
        let base = "font-family = Helvetica Neue\n"
        let bold = Cell(ch: 0x41, bits: Cell.bold)

        XCTAssertEqual(name(metrics(base + "font-style-bold = Medium").boldFont), "HelveticaNeue-Medium")
        let medium = try plannedGlyph(base + "font-style-bold = Medium", bold)
        let heavy = try plannedGlyph(base, bold)
        XCTAssertLessThan(medium.ink, heavy.ink)

        // `false` draws bold cells with the regular face, unthickened.
        let disabled = metrics(base + "font-style-bold = false")
        XCTAssertEqual(name(disabled.boldFont), "HelveticaNeue")
        XCTAssertFalse(disabled.boldIsSynthetic)
        XCTAssertEqual(try plannedGlyph(base + "font-style-bold = false", bold).mask,
                       try plannedGlyph(base, Cell(ch: 0x41)).mask)

        XCTAssertEqual(name(metrics(base + "font-style-bold = Extra Wobbly").boldFont), "HelveticaNeue-Bold")
    }

    func testItalicStyleNamesTheItalicFaceOrDisablesItalic() throws {
        try requireFamily("Helvetica Neue")
        let base = "font-family = Helvetica Neue\n"
        let italic = Cell(ch: 0x41, bits: Cell.italic)

        XCTAssertEqual(name(metrics(base + "font-style-italic = Light Italic").italicFont), "HelveticaNeue-LightItalic")
        XCTAssertNotEqual(drawn(base + "font-style-italic = \"Light Italic\"", [italic]), drawn(base, [italic]))
        XCTAssertEqual(name(metrics(base + "font-style-italic = false").italicFont), "HelveticaNeue")
        XCTAssertEqual(drawn(base + "font-style-italic = false", [italic]), drawn(base, [Cell(ch: 0x41)]))
        XCTAssertEqual(name(metrics(base + "font-style-italic = Extra Wobbly").italicFont), "HelveticaNeue-Italic")
    }

    func testBoldItalicStyleNamesTheBoldItalicFaceOrDisablesIt() throws {
        try requireFamily("Helvetica Neue")
        let base = "font-family = Helvetica Neue\n"
        let both = Cell(ch: 0x41, bits: Cell.bold | Cell.italic)

        XCTAssertEqual(name(metrics(base + "font-style-bold-italic = Medium Italic").boldItalicFont),
                       "HelveticaNeue-MediumItalic")
        XCTAssertLessThan(try plannedGlyph(base + "font-style-bold-italic = Medium Italic", both).ink,
                          try plannedGlyph(base, both).ink)
        XCTAssertEqual(name(metrics(base + "font-style-bold-italic = false").boldItalicFont), "HelveticaNeue")
        XCTAssertEqual(name(metrics(base + "font-style-bold-italic = Extra Wobbly").boldItalicFont),
                       "HelveticaNeue-BoldItalic")
    }

    // MARK: - font-synthetic-style

    func testAFamilyWithoutBoldOrItalicGetsThemSynthesised() throws {
        try requireFamily("Monaco")
        let base = "font-family = Monaco\n"
        let regular = try plannedGlyph(base, Cell(ch: 0x6C))
        let bold = try plannedGlyph(base, Cell(ch: 0x6C, bits: Cell.bold))
        let italic = try plannedGlyph(base, Cell(ch: 0x6C, bits: Cell.italic))
        let both = try plannedGlyph(base, Cell(ch: 0x6C, bits: Cell.bold | Cell.italic))

        XCTAssertGreaterThan(bold.ink, regular.ink, "a synthesised bold is thicker")
        XCTAssertGreaterThan(italic.width, regular.width, "a synthesised italic leans")
        XCTAssertGreaterThan(both.ink, italic.ink)
        XCTAssertGreaterThan(both.width, regular.width)
        XCTAssertGreaterThan(drawn(base, [Cell(ch: 0x6C, bits: Cell.bold)]).ink, drawn(base, [Cell(ch: 0x6C)]).ink)
        XCTAssertNotEqual(drawn(base, [Cell(ch: 0x6C, bits: Cell.italic)]), drawn(base, [Cell(ch: 0x6C)]))
    }

    func testSyntheticStyleTurnsSynthesisOffPerStyle() throws {
        try requireFamily("Monaco")
        let base = "font-family = Monaco\n"
        let regular = try plannedGlyph(base, Cell(ch: 0x6C))
        let italic = try plannedGlyph(base, Cell(ch: 0x6C, bits: Cell.italic))

        let noBold = base + "font-synthetic-style = no-bold\n"
        XCTAssertEqual(try plannedGlyph(noBold, Cell(ch: 0x6C, bits: Cell.bold)), regular)
        XCTAssertEqual(try plannedGlyph(noBold, Cell(ch: 0x6C, bits: Cell.italic)), italic, "italic still synthesised")
        XCTAssertEqual(drawn(noBold, [Cell(ch: 0x6C, bits: Cell.bold)]), drawn(base, [Cell(ch: 0x6C)]))

        let noItalic = base + "font-synthetic-style = bold,no-italic\n"
        XCTAssertEqual(try plannedGlyph(noItalic, Cell(ch: 0x6C, bits: Cell.italic)), regular)

        let noBoldItalic = base + "font-synthetic-style = no-bold-italic\n"
        XCTAssertEqual(try plannedGlyph(noBoldItalic, Cell(ch: 0x6C, bits: Cell.bold | Cell.italic)), regular)
        XCTAssertGreaterThan(try plannedGlyph(noBoldItalic, Cell(ch: 0x6C, bits: Cell.bold)).ink, regular.ink)

        let none = base + "font-synthetic-style = false\n"
        for bits in [Cell.bold, Cell.italic, Cell.bold | Cell.italic] {
            XCTAssertEqual(try plannedGlyph(none, Cell(ch: 0x6C, bits: bits)), regular)
        }

        // Not understood: the default, everything synthesised.
        let invalid = base + "font-synthetic-style = sideways\n"
        XCTAssertGreaterThan(try plannedGlyph(invalid, Cell(ch: 0x6C, bits: Cell.bold)).ink, regular.ink)
        XCTAssertEqual(TerminalTheme.parse(config: "font-synthetic-style = bold,wobbly").fontSyntheticStyle, .all)
        XCTAssertEqual(TerminalTheme.parse(config: "font-synthetic-style = false\nfont-synthetic-style = true")
            .fontSyntheticStyle, .all)
    }

    func testARealBoldFaceIsNeverThickened() throws {
        let metrics = metrics("font-family = Menlo")
        XCTAssertEqual(name(metrics.boldFont), "Menlo-Bold")
        XCTAssertFalse(metrics.boldIsSynthetic)
        XCTAssertFalse(metrics.boldItalicIsSynthetic)
    }

    // MARK: - font-feature


}
