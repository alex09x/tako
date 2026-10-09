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
import simd
@testable import TakoCoreUI

/// The CPU half of `MetalTerminalRenderer` -- validation, colors, selection
/// bounds, pass ordering, placement geometry and buffer growth -- is testable
/// with no GPU at all. The two tests at the bottom stand a real device up and
/// compile the shipped shaders, and skip themselves when there is no device.
final class MetalTerminalRendererTests: XCTestCase {

    // MARK: - Fixtures

    /// One packed cell, in the layout `viewport_packed` writes.
    struct CellSpec {
        var ch: UInt32 = 32
        var fg: (r: UInt8, g: UInt8, b: UInt8) = (0xed, 0xe6, 0xdf)
        var bg: (r: UInt8, g: UInt8, b: UInt8) = (0x14, 0x10, 0x0e)
        var bits: UInt16 = 0
        var underlineStyle: UInt8 = 0
        var underlineColor: (r: UInt8, g: UInt8, b: UInt8) = (0xed, 0xe6, 0xdf)

        static let boldBit: UInt16 = 1 << 0
        static let dimBit: UInt16 = 1 << 1
        static let italicBit: UInt16 = 1 << 2
        static let underlineBit: UInt16 = 1 << 3
        static let reverseBit: UInt16 = 1 << 5
        static let hiddenBit: UInt16 = 1 << 6
        static let strikethroughBit: UInt16 = 1 << 7
        static let overlineBit: UInt16 = 1 << 8
        static let wideBit: UInt16 = 1 << 9
    }

    func packed(_ cells: [CellSpec]) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(cells.count * TerminalCell.byteSize)
        for cell in cells {
            bytes.append(UInt8(truncatingIfNeeded: cell.ch))
            bytes.append(UInt8(truncatingIfNeeded: cell.ch >> 8))
            bytes.append(UInt8(truncatingIfNeeded: cell.ch >> 16))
            bytes.append(UInt8(truncatingIfNeeded: cell.ch >> 24))
            bytes.append(contentsOf: [cell.fg.r, cell.fg.g, cell.fg.b])
            bytes.append(contentsOf: [cell.bg.r, cell.bg.g, cell.bg.b])
            bytes.append(UInt8(truncatingIfNeeded: cell.bits))
            bytes.append(UInt8(truncatingIfNeeded: cell.bits >> 8))
            bytes.append(cell.underlineStyle)
            bytes.append(contentsOf: [cell.underlineColor.r, cell.underlineColor.g, cell.underlineColor.b])
        }
        return Data(bytes)
    }

    private func snapshot(
        cols: UInt32,
        rows: UInt32,
        cursorVisible: Bool = false,
        cursorRow: UInt32 = 0,
        cursorCol: UInt32 = 0,
        cursorShape: FfiCursorShape = .block,
        blinking: Bool = false,
        selection: FfiSelectionRange? = nil,
        placements: [FfiGraphicsPlacement] = [],
        viewportOffset: UInt32 = 0,
        alternateScreen: Bool = false,
        damagedRows: [UInt32]? = nil
    ) -> FfiSnapshot {
        FfiSnapshot(
            cols: cols,
            rows: rows,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            cursorVisible: cursorVisible,
            cursorStyle: FfiCursorStyle(shape: cursorShape, blinking: blinking),
            title: "test",
            modes: FfiTerminalModes(
                autowrap: true,
                originMode: false,
                cursorKeyAppMode: false,
                mouseTracking: .off,
                mouseUtf8: false,
                mouseSgr: false,
                focusEvents: false,
                bracketedPaste: false,
                alternateScreen: alternateScreen,
                alternateScroll: false
            ),
            viewportOffset: viewportOffset,
            scrollbackLen: 0,
            damagedRows: damagedRows ?? Array(0..<rows),
            selection: selection,
            graphicsPlacements: placements
        )
    }

    func frame(
        cols: UInt32,
        rows: UInt32,
        cells: [CellSpec]? = nil,
        packedOverride: Data? = nil,
        cursorVisible: Bool = false,
        cursorRow: UInt32 = 0,
        cursorCol: UInt32 = 0,
        cursorShape: FfiCursorShape = .block,
        blinking: Bool = false,
        selection: FfiSelectionRange? = nil,
        placements: [FfiGraphicsPlacement] = [],
        viewportOffset: UInt32 = 0,
        alternateScreen: Bool = false,
        damagedRows: [UInt32]? = nil
    ) -> FfiRenderFrame {
        let filled = cells ?? Array(repeating: CellSpec(), count: Int(cols) * Int(rows))
        return FfiRenderFrame(
            snapshot: snapshot(
                cols: cols,
                rows: rows,
                cursorVisible: cursorVisible,
                cursorRow: cursorRow,
                cursorCol: cursorCol,
                cursorShape: cursorShape,
                blinking: blinking,
                selection: selection,
                placements: placements,
                viewportOffset: viewportOffset,
                alternateScreen: alternateScreen,
                damagedRows: damagedRows
            ),
            packedCells: packedOverride ?? packed(filled),
            epoch: 0
        )
    }

    /// Fixed metrics so every geometry assertion is exact: 10x20 pixel cells,
    /// baseline 15 pixels down, no backing scale.
    func metrics(scale: CGFloat = 1) -> TerminalMetalCellMetrics {
        TerminalMetalCellMetrics(
            font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
            cellWidth: 10,
            cellHeight: 20,
            ascent: 15,
            scale: scale
        )
    }

    func planner(scale: CGFloat = 1) -> TerminalMetalFramePlanner {
        TerminalMetalFramePlanner(metrics: metrics(scale: scale))
    }

    let viewport = TerminalMetalViewport(drawableWidth: 200, drawableHeight: 200)


    // MARK: - Validation

    func testValidationAcceptsWellFormedFrame() {
        let frame = frame(cols: 4, rows: 3)
        XCTAssertEqual(TerminalMetalFramePlanner.validate(frame: frame, viewport: viewport), .valid)
    }

    func testValidationRejectsTruncatedPackedCells() {
        let short = frame(cols: 4, rows: 3, packedOverride: packed(Array(repeating: CellSpec(), count: 5)))
        XCTAssertEqual(
            TerminalMetalFramePlanner.validate(frame: short, viewport: viewport),
            .truncatedPackedCells(expected: 4 * 3 * TerminalCell.byteSize, actual: 5 * TerminalCell.byteSize)
        )
    }

    func testValidationReportsEmptyGrid() {
        let empty = frame(cols: 0, rows: 0, packedOverride: Data())
        XCTAssertEqual(TerminalMetalFramePlanner.validate(frame: empty, viewport: viewport), .emptyGrid)
    }

    func testValidationRejectsAbsurdGridDimensions() {
        let huge = FfiRenderFrame(
            snapshot: snapshot(cols: 4_000_000, rows: 4_000_000), packedCells: Data(), epoch: 0)
        XCTAssertEqual(
            TerminalMetalFramePlanner.validate(frame: huge, viewport: viewport),
            .invalidGridDimensions
        )
    }

    func testValidationRejectsUnusableViewport() {
        let frame = frame(cols: 2, rows: 2)
        let zero = TerminalMetalViewport(drawableWidth: 0, drawableHeight: 0)
        XCTAssertEqual(TerminalMetalFramePlanner.validate(frame: frame, viewport: zero), .invalidViewport)
        let nan = TerminalMetalViewport(drawableWidth: .nan, drawableHeight: 100)
        XCTAssertEqual(TerminalMetalFramePlanner.validate(frame: frame, viewport: nan), .invalidViewport)
    }

    func testMalformedFrameIsSkippedWholeWithoutInstances() {
        let planner = planner()
        let short = frame(cols: 8, rows: 8, packedOverride: Data([1, 2, 3]))
        let stats = planner.plan(frame: short, viewport: viewport)

        XCTAssertFalse(stats.isRenderable)
        XCTAssertEqual(stats.totalInstances, 0)
        XCTAssertEqual(planner.activePasses, [])
        XCTAssertEqual(stats.visitedCells, 0)
    }

    func testEmptyFramePlansNothing() {
        let planner = planner()
        let stats = planner.plan(frame: frame(cols: 0, rows: 0, packedOverride: Data()), viewport: viewport)

        XCTAssertEqual(stats.validation, .emptyGrid)
        XCTAssertEqual(stats.totalInstances, 0)
        XCTAssertTrue(planner.backgroundInstances.isEmpty)
        XCTAssertTrue(planner.glyphInstances.isEmpty)
    }

    // MARK: - Colors and backgrounds

    func testCellBackgroundsUseDrawablePixelGeometryAndSkipTheDefault() {
        let planner = planner()
        var cells = Array(repeating: CellSpec(), count: 4)
        cells[3].bg = (0, 0, 255)
        let stats = planner.plan(frame: frame(cols: 2, rows: 2, cells: cells), viewport: viewport)

        XCTAssertTrue(stats.isRenderable)
        XCTAssertEqual(stats.visitedCells, 4)
        // Three cells keep the palette background, which the pass clears to.
        XCTAssertEqual(planner.backgroundInstances.count, 1)
        let instance = planner.backgroundInstances[0]
        XCTAssertEqual(instance.rect, SIMD4<Float>(10, 20, 10, 20))
        XCTAssertEqual(instance.color, SIMD4<Float>(0, 0, 1, 1))
    }

    func testAdjacentEqualBackgroundsMergeIntoOneInstance() {
        let planner = planner()
        var cells = Array(repeating: CellSpec(), count: 8)
        for index in 0..<4 { cells[index].bg = (255, 0, 0) }
        let stats = planner.plan(frame: frame(cols: 4, rows: 2, cells: cells), viewport: viewport)

        XCTAssertEqual(stats.backgroundInstances, 1)
        XCTAssertEqual(planner.backgroundInstances[0].rect, SIMD4<Float>(0, 0, 40, 20))
    }

    func testBackgroundRunsDoNotSpanRows() {
        let planner = planner()
        var cells = Array(repeating: CellSpec(), count: 4)
        for index in 0..<4 { cells[index].bg = (0, 255, 0) }
        planner.plan(frame: frame(cols: 2, rows: 2, cells: cells), viewport: viewport)

        XCTAssertEqual(planner.backgroundInstances.count, 2)
        XCTAssertEqual(planner.backgroundInstances[0].rect, SIMD4<Float>(0, 0, 20, 20))
        XCTAssertEqual(planner.backgroundInstances[1].rect, SIMD4<Float>(0, 20, 20, 20))
    }

    func testReverseVideoSwapsForegroundAndBackground() {
        let planner = planner()
        var cell = CellSpec()
        cell.ch = 65
        cell.fg = (255, 0, 0)
        cell.bg = (0, 0, 255)
        cell.bits = CellSpec.reverseBit
        planner.plan(frame: frame(cols: 1, rows: 1, cells: [cell]), viewport: viewport)

        XCTAssertEqual(planner.backgroundInstances.count, 1)
        XCTAssertEqual(planner.backgroundInstances[0].color, SIMD4<Float>(1, 0, 0, 1))
        XCTAssertEqual(planner.glyphInstances.count, 1)
        XCTAssertEqual(planner.glyphInstances[0].color, SIMD4<Float>(0, 0, 1, 1))
    }

    func testLinearEncodingLinearizesComponentsAndPremultipliesGlyphColor() {
        XCTAssertEqual(TerminalMetalColor.component(255, encoding: .displayEncoded), 1)
        XCTAssertEqual(TerminalMetalColor.component(0, encoding: .linear), 0)
        XCTAssertEqual(TerminalMetalColor.component(255, encoding: .linear), 1, accuracy: 1e-5)
        // sRGB 128 is roughly 21.6% of the way up in linear light.
        XCTAssertEqual(TerminalMetalColor.component(128, encoding: .linear), 0.2158, accuracy: 1e-3)

        let premultiplied = TerminalMetalColor.premultiplied(SIMD4<Float>(1, 0.5, 0.25, 0.5))
        XCTAssertEqual(premultiplied, SIMD4<Float>(0.5, 0.25, 0.125, 0.5))
    }

    func testDimAndUnfocusedTextFadeThroughPremultipliedAlpha() {
        let planner = planner()
        planner.isFocused = false
        var cell = CellSpec()
        cell.ch = 65
        cell.fg = (255, 255, 255)
        cell.bits = CellSpec.dimBit
        planner.plan(frame: frame(cols: 1, rows: 1, cells: [cell]), viewport: viewport)

        XCTAssertEqual(planner.glyphInstances.count, 1)
        let expected = planner.palette.dimAlpha * planner.palette.unfocusedTextAlpha
        XCTAssertEqual(planner.glyphInstances[0].color.w, expected, accuracy: 1e-5)
        XCTAssertEqual(planner.glyphInstances[0].color.x, expected, accuracy: 1e-5)
    }

    func testMinimumContrastDisplayP3AndZeroAlphaAreDeterministic() {
        let same = SIMD4<Float>(0.5, 0.5, 0.5, 1)
        let adjusted = TerminalMetalColor.enforcingMinimumContrast(
            foreground: same,
            background: same,
            ratio: 7,
            encoding: .displayEncoded
        )
        XCTAssertNotEqual(adjusted.x, same.x)
        XCTAssertEqual(TerminalMetalColor.premultiplied(SIMD4<Float>(.nan, .infinity, 1, 0)), .zero)

        let srgb = TerminalMetalColor.rgba(r: 255, g: 0, b: 0, encoding: .linear, colorSpace: .sRGB)
        let p3 = TerminalMetalColor.rgba(r: 255, g: 0, b: 0, encoding: .linear, colorSpace: .displayP3)
        XCTAssertEqual(srgb, SIMD4<Float>(1, 0, 0, 1))
        XCTAssertLessThan(p3.x, srgb.x)
        XCTAssertGreaterThan(p3.y, 0)
        XCTAssertGreaterThan(p3.z, 0)
    }


}
