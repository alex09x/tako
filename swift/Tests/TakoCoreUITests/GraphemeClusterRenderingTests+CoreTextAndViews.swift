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
import Metal
import XCTest
@testable import TakoCoreUI

extension GraphemeClusterRenderingTests {
    // MARK: - CoreText

    private func cpuRender(_ frame: FfiRenderFrame) -> Pixels {
        let cols = Int(frame.snapshot.cols)
        let rows = Int(frame.snapshot.rows)
        let renderer = TerminalRenderer(metrics: .init(
            fontSize: 24, fontName: "Menlo",
            cellWidth: CGFloat(Self.cellWidth), cellHeight: CGFloat(Self.cellHeight)
        ))
        let size = renderer.pixelSize(cols: cols, rows: rows)
        let width = Int(size.width)
        let height = Int(size.height)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cells = TerminalFrame(packed: frame.packedCells, cols: cols, rows: rows)
        renderer.draw(
            in: context,
            cols: cols,
            rows: rows,
            rowProvider: { cells.row($0) },
            graphemes: frame.graphemes,
            cursorRow: 0,
            cursorCol: 0,
            cursorVisible: false,
            cursorStyle: FfiCursorStyle(shape: .block, blinking: false)
        )
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return Pixels(width: width, height: height, bytes: Array(UnsafeBufferPointer(start: data, count: width * height * 4)))
    }

    func testTheCoreTextRendererDrawsEmojiClustersInColour() {
        for text in [
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
            "\u{1F1FA}\u{1F1F8}",
            "\u{1F44D}\u{1F3FD}",
        ] {
            let cluster = cpuRender(clusterFrame(text, wide: true, withCluster: true))
            let firstScalar = cpuRender(clusterFrame(text, wide: true, withCluster: false))
            XCTAssertGreaterThan(cluster.colourful(columns: 0..<2), 50, text)
            XCTAssertGreaterThan(cluster.differing(from: firstScalar), 30, text)
        }
    }

    func testTheCoreTextRendererDrawsVS16InEmojiPresentation() {
        let arrow = "\u{2194}\u{FE0F}"
        let cluster = cpuRender(clusterFrame(arrow, wide: true, withCluster: true))
        let text = cpuRender(clusterFrame(arrow, wide: true, withCluster: false))
        XCTAssertEqual(text.colourful(columns: 0..<2), 0, "Menlo's arrow is grey")
        XCTAssertGreaterThan(cluster.colourful(columns: 0..<2), 20)
    }

    func testTheCoreTextRendererDrawsCombiningMarks() {
        for text in ["x\u{0301}\u{0323}", "\u{0915}\u{093F}", "\u{05D1}\u{05BC}\u{05B8}"] {
            let cluster = cpuRender(clusterFrame(text, wide: false, withCluster: true))
            let plain = cpuRender(clusterFrame(text, wide: false, withCluster: false))
            XCTAssertGreaterThan(cluster.ink(columns: 0..<4).count, plain.ink(columns: 0..<4).count, text)
        }
    }

    /// Clusters among plain text keep the rest of the row where it was.
    func testTheCoreTextRendererKeepsTextAfterAClusterOnTheGrid() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let cells = [
            Cell(ch: 0x1F468, bits: Self.wideBit | Self.graphemeBit), Cell(ch: 0),
            Cell(ch: 0x41), Cell(ch: 0x42),
        ]
        let withCluster = cpuRender(frame(cells: cells, graphemes: [FfiGrapheme(row: 0, col: 0, text: family)]))
        let alone = cpuRender(frame(cells: [Cell(), Cell(), Cell(ch: 0x41), Cell(ch: 0x42)]))
        XCTAssertEqual(
            withCluster.ink(columns: 2..<4).map { [$0.x, $0.y] },
            alone.ink(columns: 2..<4).map { [$0.x, $0.y] }
        )
    }

    // MARK: - Atlas

    func testTheAtlasShapesAClusterIntoOneCachedEntry() {
        let atlas = GlyphAtlas()
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let entry = atlas.clusterEntry(for: family, font: font())
        XCTAssertTrue(entry.isRasterized)
        XCTAssertEqual(entry.pixelFormat, .bgra8Premultiplied)
        XCTAssertEqual(entry.key.cluster, family)
        XCTAssertEqual(atlas.cachedCount, 1)
        XCTAssertEqual(atlas.clusterEntry(for: family, font: font()), entry)
        XCTAssertEqual(atlas.cachedCount, 1)

        let marked = atlas.clusterEntry(for: "x\u{0301}", font: font(), emboldened: true)
        XCTAssertEqual(marked.pixelFormat, .grayscale8)
        XCTAssertTrue(marked.key.emboldened)
        XCTAssertNotEqual(atlas.clusterEntry(for: "x\u{0301}", font: font()), marked)
        XCTAssertEqual(atlas.cachedCount, 3)

        let blank = atlas.clusterEntry(for: "  ", font: font())
        XCTAssertTrue(blank.isEmpty)
        XCTAssertFalse(blank.isRasterized)

        atlas.clear()
        XCTAssertEqual(atlas.cachedCount, 0)
    }

    // MARK: - grapheme-width-method

    func testGraphemeWidthMethodParses() {
        XCTAssertEqual(TerminalTheme().graphemeWidthMethod, .unicode)
        XCTAssertEqual(TerminalTheme.parse(config: "grapheme-width-method = legacy").graphemeWidthMethod, .legacy)
        XCTAssertEqual(
            TerminalTheme.parse(config: "grapheme-width-method = legacy\ngrapheme-width-method = unicode")
                .graphemeWidthMethod,
            .unicode
        )
        XCTAssertEqual(TerminalTheme.parse(config: "grapheme-width-method = wide").graphemeWidthMethod, .unicode)
    }

    func testGraphemeWidthMethodReachesTheEngine() {
        let family = Data("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".utf8)
        var theme = TerminalTheme()
        let core = TakoCore(cols: 20, rows: 2)
        theme.graphemeWidthMethod = .legacy
        core.setGraphemeWidthMethod(from: theme)
        core.feed(bytes: family)
        let legacyWidth = core.cursorCol()

        theme.graphemeWidthMethod = .unicode
        core.setGraphemeWidthMethod(from: theme)
        core.feed(bytes: Data("\r\n".utf8) + family)
        XCTAssertEqual(core.cursorCol(), 2)
        XCTAssertGreaterThan(legacyWidth, 2)
    }
}


}
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class GraphemeClusterNSViewTests: XCTestCase {
    private let family = Data("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".utf8)

    func testTheViewAppliesGraphemeWidthMethodAtInitAndOnAThemeChange() {
        var theme = TerminalTheme.takoDefault
        theme.graphemeWidthMethod = .legacy
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), theme: theme)
        view.core.feed(bytes: family)
        XCTAssertGreaterThan(view.core.cursorCol(), 2)

        theme.graphemeWidthMethod = .unicode
        view.theme = theme
        view.core.feed(bytes: Data("\r\n".utf8) + family)
        XCTAssertEqual(view.core.cursorCol(), 2)

        theme.graphemeWidthMethod = .legacy
        view.theme = theme
        view.core.feed(bytes: Data("\r\n".utf8) + family)
        XCTAssertGreaterThan(view.core.cursorCol(), 2)
    }

    /// A URL after clusters is found at its columns, not at its offset in
    /// the row's text.
    func testAURLAfterClustersIsFoundAtItsColumns() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400))
        view.core.feed(bytes: family + Data(" x\u{0301} https://example.com/a".utf8))
        // Family: columns 0-1, space 2, x-acute 3, space 4, the URL from 5.
        let link = try XCTUnwrap(view.linkRange(at: (row: 0, col: 6)))
        XCTAssertEqual(link.url, URL(string: "https://example.com/a"))
        XCTAssertEqual(link.colStart, 5)
        XCTAssertEqual(link.colEnd, 25)
        XCTAssertNil(view.linkRange(at: (row: 0, col: 3)))
    }

    /// The text the view hands out holds whole clusters, and its length is
    /// counted in the UTF-16 units accessibility ranges use.
    func testAccessibilityTextHoldsWholeClusters() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.core.feed(bytes: family + Data("x\u{0301}\u{0323}".utf8))
        let value = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertTrue(value.hasPrefix("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}x\u{0301}\u{0323}"))
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), value.utf16.count)

        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 2)
        XCTAssertEqual(view.accessibilitySelectedText()?.hasPrefix("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"), true)
    }
}
#endif

#if canImport(UIKit)
import UIKit

@MainActor
final class GraphemeClusterUIViewTests: XCTestCase {
    func testTheViewAppliesGraphemeWidthMethodAtInitAndOnAThemeChange() {
        let family = Data("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".utf8)
        var theme = TerminalTheme.takoDefault
        theme.graphemeWidthMethod = .legacy
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200), theme: theme)
        view.core.feed(bytes: family)
        XCTAssertGreaterThan(view.core.cursorCol(), 2)

        theme.graphemeWidthMethod = .unicode
        view.theme = theme
        view.core.feed(bytes: Data("\r\n".utf8) + family)
        XCTAssertEqual(view.core.cursorCol(), 2)
    }
}
#endif
