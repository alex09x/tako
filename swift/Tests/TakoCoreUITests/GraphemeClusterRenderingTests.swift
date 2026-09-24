import CoreGraphics
import CoreText
import Foundation
import Metal
import XCTest
@testable import TakoCoreUI

/// A cell holding a multi-codepoint grapheme cluster is drawn as that
/// cluster, not as its first scalar.
///
/// Every witness here is pixels or instance counts compared against the same
/// frame with its clusters withheld, which is exactly what both renderers drew
/// before they read `graphemes`: the cell's `ch` alone. A render that ignores
/// the clusters matches that baseline and fails.
final class GraphemeClusterRenderingTests: XCTestCase {

    // MARK: - Fixtures

    private static let cellWidth = 16
    private static let cellHeight = 32
    private static let wideBit: UInt16 = 1 << 9
    private static let graphemeBit: UInt16 = 1 << 10

    private struct Cell {
        var ch: UInt32 = 32
        var bits: UInt16 = 0
    }

    /// White on black, so ink is anything that is not black.
    private func packed(_ cells: [Cell]) -> Data {
        var bytes = [UInt8]()
        for cell in cells {
            bytes.append(UInt8(truncatingIfNeeded: cell.ch))
            bytes.append(UInt8(truncatingIfNeeded: cell.ch >> 8))
            bytes.append(UInt8(truncatingIfNeeded: cell.ch >> 16))
            bytes.append(UInt8(truncatingIfNeeded: cell.ch >> 24))
            bytes.append(contentsOf: [0xff, 0xff, 0xff, 0, 0, 0])
            bytes.append(UInt8(truncatingIfNeeded: cell.bits))
            bytes.append(UInt8(truncatingIfNeeded: cell.bits >> 8))
            bytes.append(contentsOf: [0, 0xff, 0xff, 0xff])
        }
        return Data(bytes)
    }

    /// Row 0 holds `cells`, padded with spaces to `cols`.
    private func frame(
        cols: Int = 4,
        cells: [Cell],
        graphemes: [FfiGrapheme] = [],
        damagedRows: [UInt32] = [0]
    ) -> FfiRenderFrame {
        let row = cells + Array(repeating: Cell(), count: max(cols - cells.count, 0))
        return FfiRenderFrame(
            snapshot: FfiSnapshot(
                cols: UInt32(cols),
                rows: 1,
                cursorRow: 0,
                cursorCol: 0,
                cursorVisible: false,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
                title: "",
                modes: FfiTerminalModes(
                    autowrap: true,
                    originMode: false,
                    cursorKeyAppMode: false,
                    mouseTracking: .off,
                    mouseUtf8: false,
                    mouseSgr: false,
                    focusEvents: false,
                    bracketedPaste: false
                ),
                viewportOffset: 0,
                scrollbackLen: 0,
                damagedRows: damagedRows,
                selection: nil,
                graphicsPlacements: []
            ),
            packedCells: packed(row),
            epoch: 0,
            graphemes: graphemes
        )
    }

    /// A cluster at column 0, wide when it is an emoji.
    private func clusterFrame(_ text: String, wide: Bool, withCluster: Bool) -> FfiRenderFrame {
        let first = text.unicodeScalars.first!.value
        var cells = [Cell(ch: first, bits: Self.graphemeBit | (wide ? Self.wideBit : 0))]
        if wide { cells.append(Cell(ch: 0)) }
        return frame(
            cells: cells,
            graphemes: withCluster ? [FfiGrapheme(row: 0, col: 0, text: text)] : []
        )
    }

    private func font() -> CTFont {
        CTFontCreateWithName("Menlo" as CFString, 24, nil)
    }

    private func metalMetrics() -> TerminalMetalCellMetrics {
        TerminalMetalCellMetrics(
            font: font(),
            cellWidth: CGFloat(Self.cellWidth),
            cellHeight: CGFloat(Self.cellHeight),
            ascent: 25,
            scale: 1
        )
    }

    // MARK: - Pixels

    private struct Pixels: Equatable {
        let width: Int
        let height: Int
        /// Four bytes per pixel; the colour order does not matter to any
        /// property checked here.
        let bytes: [UInt8]

        func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2])
        }

        /// Pixels in `columns` that are not black.
        func ink(columns: Range<Int>) -> [(x: Int, y: Int)] {
            var out: [(x: Int, y: Int)] = []
            for y in 0..<height {
                for x in (columns.lowerBound * cellWidth)..<min(columns.upperBound * cellWidth, width) {
                    let (a, b, c) = pixel(x: x, y: y)
                    if Int(a) + Int(b) + Int(c) > 48 { out.append((x, y)) }
                }
            }
            return out
        }

        /// Pixels whose channels disagree: colour, not grey text.
        func colourful(columns: Range<Int>) -> Int {
            ink(columns: columns).count { point in
                let (a, b, c) = pixel(x: point.x, y: point.y)
                return max(a, b, c) - min(a, b, c) > 16
            }
        }

        func differing(from other: Pixels, columns: Range<Int>? = nil) -> Int {
            var count = 0
            for y in 0..<height {
                for x in 0..<width where columns.map({ $0.contains(x / cellWidth) }) ?? true {
                    let i = (y * width + x) * 4
                    if (0..<3).contains(where: { abs(Int(bytes[i + $0]) - Int(other.bytes[i + $0])) > 24 }) {
                        count += 1
                    }
                }
            }
            return count
        }

        private var cellWidth: Int { GraphemeClusterRenderingTests.cellWidth }
    }

    // MARK: - Metal

    private func device() throws -> MTLDevice {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        try XCTSkipUnless(device.hasUnifiedMemory, "reading a texture back needs shared storage")
        return device
    }

    private func makeRenderer(_ device: MTLDevice) throws -> MetalTerminalRenderer {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        return try MetalTerminalRenderer(device: device, library: library, metrics: metalMetrics())
    }

    private func render(_ frame: FfiRenderFrame, with renderer: MetalTerminalRenderer) throws -> Pixels {
        let cols = Int(frame.snapshot.cols)
        let width = cols * Self.cellWidth
        let height = Int(frame.snapshot.rows) * Self.cellHeight
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = renderer.clearColor
        let stats = renderer.render(
            frame: frame,
            viewport: TerminalMetalViewport(drawableWidth: Float(width), drawableHeight: Float(height)),
            descriptor: pass,
            waitUntilCompleted: true
        )
        XCTAssertTrue(stats.isRenderable)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private func renderFresh(_ frame: FfiRenderFrame, device: MTLDevice) throws -> (Pixels, TerminalMetalFrameStatistics) {
        let renderer = try makeRenderer(device)
        let pixels = try render(frame, with: renderer)
        return (pixels, renderer.statistics)
    }

    func testAZWJFamilyIsOneColourGlyphOverBothOfItsCells() throws {
        let device = try device()
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let (cluster, stats) = try renderFresh(clusterFrame(family, wide: true, withCluster: true), device: device)
        let (firstScalar, _) = try renderFresh(clusterFrame(family, wide: true, withCluster: false), device: device)

        XCTAssertEqual(stats.colorGlyphInstances, 1, "one colour quad for the whole sequence")
        XCTAssertEqual(stats.glyphInstances, 1)
        XCTAssertGreaterThan(cluster.colourful(columns: 0..<2), 50)
        XCTAssertFalse(cluster.ink(columns: 0..<1).isEmpty, "the glyph covers the first cell")
        XCTAssertFalse(cluster.ink(columns: 1..<2).isEmpty, "and the second")
        XCTAssertTrue(cluster.ink(columns: 2..<4).isEmpty, "and nothing past them")
        XCTAssertGreaterThan(cluster.differing(from: firstScalar), 50, "the family, not the man alone")
    }

    func testProfessionSkinToneAndFlagDrawAsTheirCluster() throws {
        let device = try device()
        for text in [
            "\u{1F469}\u{200D}\u{1F4BB}",   // woman technologist
            "\u{1F44D}\u{1F3FD}",           // thumbs up, medium skin tone
            "\u{1F1FA}\u{1F1F8}",           // flag: United States
        ] {
            let (cluster, stats) = try renderFresh(clusterFrame(text, wide: true, withCluster: true), device: device)
            let (firstScalar, _) = try renderFresh(clusterFrame(text, wide: true, withCluster: false), device: device)
            XCTAssertEqual(stats.colorGlyphInstances, 1, text)
            XCTAssertGreaterThan(cluster.colourful(columns: 0..<2), 50, text)
            XCTAssertGreaterThan(cluster.differing(from: firstScalar), 30, text)
        }
    }

    /// U+2194 has a text glyph in Menlo; VS16 asks for the emoji instead.
    func testAVS16SequenceDrawsInEmojiPresentation() throws {
        let device = try device()
        let arrow = "\u{2194}\u{FE0F}"
        let (cluster, stats) = try renderFresh(clusterFrame(arrow, wide: true, withCluster: true), device: device)
        let (_, textStats) = try renderFresh(clusterFrame(arrow, wide: true, withCluster: false), device: device)
        XCTAssertEqual(textStats.colorGlyphInstances, 0, "the base alone is Menlo's text arrow")
        XCTAssertEqual(stats.colorGlyphInstances, 1)
        XCTAssertEqual(stats.glyphInstances, 1)
        XCTAssertGreaterThan(cluster.colourful(columns: 0..<2), 20)
    }

    /// Neither x-acute nor x-dot-below has a precomposed form, so the marks
    /// only show if the cluster is shaped: one above the x, one below it,
    /// both on the x's own cell.
    func testCombiningMarksWithoutAPrecomposedFormSitOnTheirBase() throws {
        let device = try device()
        let text = "x\u{0301}\u{0323}"
        let (cluster, stats) = try renderFresh(clusterFrame(text, wide: false, withCluster: true), device: device)
        let (plain, _) = try renderFresh(clusterFrame(text, wide: false, withCluster: false), device: device)
        XCTAssertEqual(stats.glyphInstances, 1)
        XCTAssertEqual(stats.colorGlyphInstances, 0)

        let marked = cluster.ink(columns: 0..<4)
        let base = plain.ink(columns: 0..<4)
        let markedTop = try XCTUnwrap(marked.map(\.y).min())
        let markedBottom = try XCTUnwrap(marked.map(\.y).max())
        let baseTop = try XCTUnwrap(base.map(\.y).min())
        let baseBottom = try XCTUnwrap(base.map(\.y).max())
        XCTAssertLessThan(markedTop, baseTop - 2, "the acute sits above the x")
        XCTAssertGreaterThan(markedBottom, baseBottom + 1, "the dot sits below it")
        XCTAssertTrue(marked.allSatisfy { $0.x < Self.cellWidth + 2 }, "both marks stay on the x's cell")
    }

    func testDevanagariHebrewPointsAndStackedIPAMarksDrawTheirMarks() throws {
        let device = try device()
        for text in [
            "\u{0915}\u{093F}",             // Devanagari ka + vowel sign i
            "\u{05D1}\u{05BC}\u{05B8}",     // Hebrew bet + dagesh + qamats
            "\u{0261}\u{030A}\u{0303}",     // IPA script g + ring above + tilde
        ] {
            let (cluster, _) = try renderFresh(clusterFrame(text, wide: false, withCluster: true), device: device)
            let (plain, _) = try renderFresh(clusterFrame(text, wide: false, withCluster: false), device: device)
            XCTAssertGreaterThan(cluster.ink(columns: 0..<4).count, plain.ink(columns: 0..<4).count, text)
            XCTAssertGreaterThan(cluster.differing(from: plain), 8, text)
        }
    }

    /// The packed bytes carry only the first scalar, so these two frames are
    /// byte-identical and neither reports damage. The row cache has to see
    /// the cluster change anyway.
    func testAChangedClusterWithTheSameFirstScalarIsRedrawn() throws {
        let device = try device()
        let technologist = "\u{1F469}\u{200D}\u{1F4BB}"
        let astronaut = "\u{1F469}\u{200D}\u{1F680}"
        var first = clusterFrame(technologist, wide: true, withCluster: true)
        var second = clusterFrame(astronaut, wide: true, withCluster: true)
        XCTAssertEqual(first.packedCells, second.packedCells)
        first.snapshot.damagedRows = [0]
        second.snapshot.damagedRows = []

        let renderer = try makeRenderer(device)
        let before = try render(first, with: renderer)
        let after = try render(second, with: renderer)
        XCTAssertEqual(renderer.statistics.replannedRows, 1)
        let (expected, _) = try renderFresh(second, device: device)
        XCTAssertEqual(after.differing(from: expected), 0, "the reused renderer shows the new cluster")
        XCTAssertGreaterThan(after.differing(from: before), 30)

        // An unchanged cluster is still reused.
        _ = try render(second, with: renderer)
        XCTAssertEqual(renderer.statistics.replannedRows, 0)
    }

    /// A space leading a cluster still draws the marks on it.
    func testAClusterOnASpaceIsDrawn() throws {
        let device = try device()
        let (_, stats) = try renderFresh(clusterFrame(" \u{0301}", wide: false, withCluster: true), device: device)
        XCTAssertEqual(stats.glyphInstances, 1)
        let (_, bare) = try renderFresh(clusterFrame(" \u{0301}", wide: false, withCluster: false), device: device)
        XCTAssertEqual(bare.glyphInstances, 0)
    }

    /// The engine's own frame: its `graphemes` rows and columns address the
    /// cells the planner draws them on.
    func testTheEnginesClustersReachTheScreen() throws {
        let device = try device()
        let core = TakoCore(cols: 6, rows: 1)
        core.feed(bytes: Data("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}x\u{0301}\u{0323}".utf8))
        let live = core.renderFrame()
        XCTAssertEqual(live.graphemes.map(\.col), [0, 2])
        var withheld = live
        withheld.graphemes = []

        let (cluster, stats) = try renderFresh(live, device: device)
        let (firstScalars, _) = try renderFresh(withheld, device: device)
        XCTAssertEqual(stats.colorGlyphInstances, 1)
        XCTAssertGreaterThan(cluster.colourful(columns: 0..<2), 50)
        XCTAssertGreaterThan(cluster.differing(from: firstScalars), 50)
        XCTAssertGreaterThan(cluster.differing(from: firstScalars, columns: 2..<3), 8, "the marks on the x")
    }

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
