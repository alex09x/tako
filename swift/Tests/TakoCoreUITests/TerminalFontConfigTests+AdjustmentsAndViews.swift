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
import Metal
import XCTest
@testable import TakoCoreUI

extension TerminalFontConfigTests {
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

}
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
