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

    private struct Cell {
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

    private func planner(_ config: String, _ cells: [Cell]) -> TerminalMetalFramePlanner {
        let planner = TerminalMetalFramePlanner(metrics: TerminalMetalCellMetrics(metrics(config), scale: 1))
        planner.plan(frame: frame(cells), viewport: TerminalMetalViewport(drawableWidth: 400, drawableHeight: 200))
        return planner
    }

    /// The atlas mask the GPU draws for one cell, and where it lands.
    private struct PlannedGlyph: Equatable {
        let mask: [UInt8]
        let width: Int
        let height: Int
        let top: Float
        var ink: Int { mask.reduce(0) { $0 + Int($1) } }
    }

    private func plannedGlyph(_ config: String, _ cell: Cell) throws -> PlannedGlyph {
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
    private struct Bitmap: Equatable {
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

    private func drawn(_ config: String, _ cells: [Cell]) -> Bitmap {
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

    func testAFontFeatureSubstitutesTheGlyphThatIsDrawn() throws {
        try requireFamily("Hiragino Sans")
        let base = "font-family = Hiragino Sans\n"
        let zero = Cell(ch: 0x30)
        let plain = try plannedGlyph(base, zero)

        XCTAssertNotEqual(try plannedGlyph(base + "font-feature = zero", zero).mask, plain.mask,
                          "the slashed zero is a different glyph")
        XCTAssertNotEqual(drawn(base + "font-feature = zero", [zero]), drawn(base, [zero]))
        XCTAssertNotEqual(try plannedGlyph(base + "font-feature = +zero", Cell(ch: 0x30, bits: Cell.bold)).mask,
                          try plannedGlyph(base, Cell(ch: 0x30, bits: Cell.bold)).mask,
                          "features apply to styled faces too")

        XCTAssertEqual(try plannedGlyph(base + "font-feature = -zero", zero), plain)
        XCTAssertEqual(try plannedGlyph(base + "font-feature = zero\nfont-feature =", zero), plain,
                       "an empty value clears the list")
        // Malformed: not a four-letter tag, so nothing changes.
        XCTAssertEqual(try plannedGlyph(base + "font-feature = zeroo", zero), plain)
        XCTAssertEqual(drawn(base + "font-feature = zeroo", [zero]), drawn(base, [zero]))
    }

    func testFontFeatureSyntax() {
        typealias Feature = TerminalTheme.FontFeature
        func features(_ lines: String...) -> [Feature] {
            TerminalTheme.parse(config: lines.map { "font-feature = \($0)" }.joined(separator: "\n")).fontFeatures
        }
        XCTAssertEqual(features("ss01"), [Feature(tag: "ss01", value: 1)])
        XCTAssertEqual(features("-calt"), [Feature(tag: "calt", value: 0)])
        XCTAssertEqual(features("+liga"), [Feature(tag: "liga", value: 1)])
        XCTAssertEqual(features("cv01=2"), [Feature(tag: "cv01", value: 2)])
        XCTAssertEqual(features("cv01 = 3"), [Feature(tag: "cv01", value: 3)])
        XCTAssertEqual(features("cv02 4"), [Feature(tag: "cv02", value: 4)])
        XCTAssertEqual(features("liga off", "\"calt\" on"),
                       [Feature(tag: "liga", value: 0), Feature(tag: "calt", value: 1)])
        XCTAssertEqual(features("ss01, -calt"), [Feature(tag: "ss01", value: 1), Feature(tag: "calt", value: 0)])
        XCTAssertEqual(features("zero", "ss02", "-zero"),
                       [Feature(tag: "ss02", value: 1), Feature(tag: "zero", value: 0)], "the last setting wins")
        XCTAssertEqual(features("zero", "cv01=x"), [Feature(tag: "zero", value: 1)])
        XCTAssertEqual(features("ss01", "abc"), [Feature(tag: "ss01", value: 1)])
        XCTAssertEqual(features("cv01=-1"), [])
    }

    func testDisablingLigaturesStillKeepsEveryCellOnTheGrid() throws {
        let base = "font-family = Menlo\nfont-feature = -calt, -liga\n"
        let cells = "->=".unicodeScalars.map { Cell(ch: $0.value) }
        let planner = planner(base, cells)
        XCTAssertEqual(planner.glyphInstances.count, 3)
        let width = Float(metrics(base).cellWidth)
        for (index, instance) in planner.glyphInstances.enumerated() {
            XCTAssertGreaterThanOrEqual(instance.destRect.x, Float(index) * width - 1)
            XCTAssertLessThanOrEqual(instance.destRect.x + instance.destRect.z, Float(index + 1) * width + 1)
        }
        XCTAssertEqual(drawn(base, cells).width, Int(width) * 3)
    }

    // MARK: - adjust-cell-width, adjust-cell-height

    func testAdjustCellWidthWidensTheGrid() {
        let base = "font-family = Menlo\n"
        let width = metrics(base).cellWidth

        XCTAssertEqual(metrics(base + "adjust-cell-width = +2").cellWidth, width + 2)
        XCTAssertEqual(metrics(base + "adjust-cell-width = -1").cellWidth, width - 1)
        XCTAssertEqual(metrics(base + "adjust-cell-width = 20%").cellWidth, (width * 1.2).rounded())
        XCTAssertEqual(drawn(base + "adjust-cell-width = +2", [Cell(ch: 0x41), Cell(ch: 0x42)]).width,
                       Int(width + 2) * 2)
        let planner = planner(base + "adjust-cell-width = +2", [Cell(ch: 0x41, bits: Cell.underline)])
        XCTAssertEqual(planner.decorationInstances.first?.rect.z, Float(width + 2))

        XCTAssertEqual(metrics(base + "adjust-cell-width = wide").cellWidth, width)
        XCTAssertEqual(metrics(base + "adjust-cell-width = 1.5").cellWidth, width)
        XCTAssertEqual(metrics(base + "adjust-cell-width = -500").cellWidth, 1, "never narrower than a point")
        XCTAssertEqual(metrics(base + "cell-width = 12\nadjust-cell-width = +1").cellWidth, 13,
                       "adjusts a configured cell width too")
    }

    func testAdjustCellHeightGrowsTheRowAndKeepsTextCentred() throws {
        let base = "font-family = Menlo\n"
        let plain = metrics(base)
        let taller = metrics(base + "adjust-cell-height = +4")

        XCTAssertEqual(taller.cellHeight, plain.cellHeight + 4)
        XCTAssertEqual(taller.baseline, plain.baseline + 2)
        XCTAssertEqual(drawn(base + "adjust-cell-height = +4", [Cell(ch: 0x41)]).height, Int(plain.cellHeight) + 4)
        XCTAssertEqual(try plannedGlyph(base + "adjust-cell-height = +4", Cell(ch: 0x41)).top,
                       try plannedGlyph(base, Cell(ch: 0x41)).top + 2, "the glyph moves down half the growth")
        XCTAssertEqual(metrics(base + "adjust-cell-height = -10%").cellHeight, (plain.cellHeight * 0.9).rounded())

        XCTAssertEqual(metrics(base + "adjust-cell-height = tall").cellHeight, plain.cellHeight)
        XCTAssertEqual(metrics(base + "adjust-cell-height = %").cellHeight, plain.cellHeight)
        XCTAssertEqual(metrics(base + "adjust-cell-height = +4\nadjust-cell-height =").cellHeight, plain.cellHeight)
    }

    // MARK: - adjust-font-baseline

    func testAdjustFontBaselineRaisesTheText() throws {
        let base = "font-family = Menlo\n"
        let plain = metrics(base)
        let cell = Cell(ch: 0x41)

        XCTAssertEqual(metrics(base + "adjust-font-baseline = +3").baseline, plain.baseline + 3)
        XCTAssertEqual(try plannedGlyph(base + "adjust-font-baseline = +3", cell).top,
                       try plannedGlyph(base, cell).top - 3)
        let raised = drawn(base + "adjust-font-baseline = 2", [cell]).inkRows
        let normal = drawn(base, [cell]).inkRows
        XCTAssertEqual(raised.first, normal.first.map { $0 - 2 })
        XCTAssertEqual(metrics(base + "adjust-font-baseline = 50%").baseline, (plain.baseline * 1.5).rounded())

        XCTAssertEqual(metrics(base + "adjust-font-baseline = up").baseline, plain.baseline)
        XCTAssertEqual(try plannedGlyph(base + "adjust-font-baseline = up", cell).top,
                       try plannedGlyph(base, cell).top)
    }

    // MARK: - adjust-underline-position, adjust-underline-thickness

    func testAdjustUnderlinePositionMovesTheUnderline() {
        let base = "font-family = Menlo\n"
        let cell = Cell(ch: 0x20, bits: Cell.underline, underlineStyle: 1)
        let plainRows = drawn(base, [cell]).underlineRows
        let plainTop = planner(base, [cell]).decorationInstances.first?.rect.y

        XCTAssertEqual(drawn(base + "adjust-underline-position = +2", [cell]).underlineRows,
                       plainRows.map { $0 + 2 })
        XCTAssertEqual(planner(base + "adjust-underline-position = +2", [cell]).decorationInstances.first?.rect.y,
                       plainTop.map { $0 + 2 })
        XCTAssertEqual(drawn(base + "adjust-underline-position = -1", [cell]).underlineRows,
                       plainRows.map { $0 - 1 })
        let position = metrics(base).underlinePosition
        XCTAssertEqual(metrics(base + "adjust-underline-position = -10%").underlinePosition,
                       (position * 0.9).rounded())

        XCTAssertEqual(drawn(base + "adjust-underline-position = low", [cell]).underlineRows, plainRows)
        XCTAssertEqual(planner(base + "adjust-underline-position = low", [cell]).decorationInstances.first?.rect.y,
                       plainTop)
    }

    func testAdjustUnderlineThicknessThickensTheUnderline() {
        let base = "font-family = Menlo\n"
        let cell = Cell(ch: 0x20, bits: Cell.underline, underlineStyle: 1)
        let plainRows = drawn(base, [cell]).underlineRows
        XCTAssertEqual(plainRows.count, 1)

        XCTAssertEqual(drawn(base + "adjust-underline-thickness = +2", [cell]).underlineRows.count, 3)
        XCTAssertEqual(drawn(base + "adjust-underline-thickness = +2", [cell]).underlineRows.first, plainRows.first,
                       "it grows downward from the same top edge")
        let thick = planner(base + "adjust-underline-thickness = 200%", [cell]).decorationInstances.first
        XCTAssertEqual(thick?.rect.w, 3)
        XCTAssertEqual(thick?.thickness, 3)
        XCTAssertEqual(planner(base + "adjust-underline-thickness = +1", [Cell(ch: 0x20, bits: Cell.underline,
                                                                              underlineStyle: 2)])
            .decorationInstances.first?.rect.w, 8, "a double underline is four line widths tall")
        // Strikethrough keeps its own weight.
        XCTAssertEqual(planner(base + "adjust-underline-thickness = +2", [Cell(ch: 0x20, bits: 1 << 7)])
            .decorationInstances.first?.rect.w, 1)

        XCTAssertEqual(drawn(base + "adjust-underline-thickness = fat", [cell]).underlineRows, plainRows)
        XCTAssertEqual(planner(base + "adjust-underline-thickness = fat", [cell]).decorationInstances.first?.rect.w, 1)
        XCTAssertEqual(metrics(base + "adjust-underline-thickness = -5").underlineThickness, 1,
                       "never thinner than a point")
    }

    func testEveryUnderlineStyleFollowsTheAdjustedThickness() {
        let base = "font-family = Menlo\nadjust-underline-thickness = +1\n"
        for style in UInt8(1)...5 {
            let rows = drawn(base, [Cell(ch: 0x20, bits: Cell.underline, underlineStyle: style),
                                    Cell(ch: 0x20, bits: Cell.underline, underlineStyle: style)]).underlineRows
            XCTAssertGreaterThanOrEqual(rows.count, 2, "style \(style)")
        }
    }

    // MARK: - Themes

    func testAThemeFileLeavesTheFontKeysAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "background = #102030\nadjust-cell-width = +9\nfont-feature = ss05\nfont-style-bold = false\n"
            .write(to: dir.appendingPathComponent("fonty"), atomically: true, encoding: .utf8)

        let theme = TerminalTheme.parse(
            config: "theme = fonty\nadjust-cell-width = +1\nfont-feature = zero\n",
            base: TerminalTheme(),
            honourTheme: true,
            themeSearchPaths: [dir.path])
        XCTAssertEqual(theme.adjustCellWidth, .points(1))
        XCTAssertEqual(theme.fontFeatures, [TerminalTheme.FontFeature(tag: "zero", value: 1)])
        XCTAssertEqual(theme.fontStyleBold, .default)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// The macOS view builds its grid and both renderers from the theme's font
/// keys, and a theme change rebuilds them.
@MainActor
final class TerminalFontConfigNSViewTests: XCTestCase {
    /// Grid resizes settle on the main queue.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testTheViewsGridFollowsTheAdjustedCell() async throws {
        let plain = TerminalTheme.parse(config: "font-family = Menlo\nwindow-padding-x = 0")
        let wider = TerminalTheme.parse(config: "font-family = Menlo\nwindow-padding-x = 0\nadjust-cell-width = 50%")
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), theme: plain)
        let plainWidth = view.cellWidth
        view.setFrameSize(NSSize(width: 600, height: 200))
        try await settle()
        let plainCols = view.cols
        XCTAssertEqual(plainCols, Int(600 / plainWidth))

        view.theme = wider
        view.setFrameSize(NSSize(width: 600, height: 200))
        try await settle()
        XCTAssertEqual(view.cellWidth, (plainWidth * 1.5).rounded())
        XCTAssertEqual(view.cols, Int(600 / view.cellWidth))
        XCTAssertLessThan(view.cols, plainCols)
        if let metal = view.metalRenderer {
            XCTAssertEqual(metal.planner.metrics.cellWidth, view.cellWidth)
        }
    }

    func testTheViewDrawsBoldWithTheConfiguredFamily() throws {
        let theme = TerminalTheme.parse(config: "font-family = Menlo\nfont-family-bold = Courier New")
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), theme: theme)
        XCTAssertEqual(CTFontCopyPostScriptName(view.renderer.metrics.boldFont) as String, "CourierNewPS-BoldMT")
        if let metal = view.metalRenderer {
            XCTAssertEqual(metal.planner.resolvedFontName(for: 0x41, bold: true), "CourierNewPS-BoldMT")
        }
    }
}
#endif

#if canImport(UIKit)
import UIKit

/// The iOS view shares the renderer and reads the same theme.
@MainActor
final class TerminalFontConfigUIViewTests: XCTestCase {
    func testTheIOSViewReadsTheFontKeys() {
        let plain = TerminalTheme.parse(config: "font-family = Menlo")
        let adjusted = TerminalTheme.parse(config: "font-family = Menlo\nadjust-cell-height = +6\nfont-style-bold = false")
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200), theme: plain)
        let height = view.renderer.metrics.cellHeight

        view.theme = adjusted
        XCTAssertEqual(view.renderer.metrics.cellHeight, height + 6)
        XCTAssertEqual(CTFontCopyPostScriptName(view.renderer.metrics.boldFont) as String, "Menlo-Regular")
        if let metal = view.metalRenderer {
            XCTAssertEqual(metal.planner.metrics.cellHeight, height + 6)
        }
    }
}
#endif
