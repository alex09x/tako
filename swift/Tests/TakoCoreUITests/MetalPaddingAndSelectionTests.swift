import Metal
import XCTest
@testable import TakoCoreUI

/// window-padding-*, selection-foreground, selection-invert-fg-bg and
/// window-colorspace on the Metal path -- the one that draws the app.
final class MetalPaddingAndSelectionTests: XCTestCase {
    private static let cellWidth = 8
    private static let cellHeight = 16
    private static let cols = 4
    private static let rows = 4
    private static let rowColors: [(UInt8, UInt8, UInt8)] = [(200, 0, 0), (0, 200, 0), (0, 0, 200), (200, 200, 0)]
    private static let defaultBackground: (UInt8, UInt8, UInt8) = (0x14, 0x10, 0x0e)

    private func device() throws -> MTLDevice {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        try XCTSkipUnless(device.hasUnifiedMemory, "reading a texture back needs shared storage")
        return device
    }

    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }

    private func packedCell(bg: (UInt8, UInt8, UInt8), char: UInt32 = 32, fg: (UInt8, UInt8, UInt8) = (255, 255, 255)) -> [UInt8] {
        var bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: char), UInt8(truncatingIfNeeded: char >> 8),
            UInt8(truncatingIfNeeded: char >> 16), UInt8(truncatingIfNeeded: char >> 24),
        ]
        bytes.append(contentsOf: [fg.0, fg.1, fg.2, bg.0, bg.1, bg.2, 0, 0, 0, 255, 255, 255])
        precondition(bytes.count == TerminalCell.byteSize)
        return bytes
    }

    /// Every row one flat colour; `row0` replaces the first row's cells.
    private func frame(
        inked: Bool = false,
        row0: [(UInt8, UInt8, UInt8)]? = nil,
        selection: FfiSelectionRange? = nil
    ) -> FfiRenderFrame {
        var bytes = [UInt8]()
        for row in 0..<Self.rows {
            for col in 0..<Self.cols {
                let bg = row == 0 ? (row0?[col] ?? Self.rowColors[0]) : Self.rowColors[row]
                bytes += packedCell(bg: bg, char: inked ? 0x2588 : 32) // U+2588 FULL BLOCK
            }
        }
        return FfiRenderFrame(
            snapshot: FfiSnapshot(
                cols: UInt32(Self.cols), rows: UInt32(Self.rows),
                cursorRow: 3, cursorCol: 3, cursorVisible: false,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
                title: "padding",
                modes: FfiTerminalModes(
                    autowrap: true, originMode: false, cursorKeyAppMode: false,
                    mouseTracking: .off, mouseUtf8: false, mouseSgr: false,
                    focusEvents: false, bracketedPaste: false
                ),
                viewportOffset: 0, scrollbackLen: 0,
                damagedRows: Array(0..<UInt32(Self.rows)),
                selection: selection, graphicsPlacements: []
            ),
            packedCells: Data(bytes),
            epoch: 0
        )
    }

    private func renderer(device: MTLDevice) throws -> MetalTerminalRenderer {
        try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: TerminalMetalCellMetrics(
                font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
                cellWidth: CGFloat(Self.cellWidth), cellHeight: CGFloat(Self.cellHeight),
                ascent: 13, scale: 1
            ),
            palette: TerminalMetalPalette(
                background: TerminalMetalColor.rgba(r: 0x14, g: 0x10, b: 0x0e),
                foreground: TerminalMetalColor.rgba(r: 255, g: 255, b: 255),
                selection: TerminalMetalColor.rgba(r: 0, g: 255, b: 255, alpha: 0.5),
                cursor: TerminalMetalColor.rgba(r: 255, g: 0, b: 0)
            )
        )
    }

    private struct Pixels {
        let width: Int
        let bytes: [UInt8]
        func at(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * width + x) * 4
            return [bytes[i + 2], bytes[i + 1], bytes[i]]
        }
    }

    private func render(
        _ frame: FfiRenderFrame,
        margins: TerminalMetalMargins,
        device: MTLDevice
    ) throws -> (Pixels, width: Int, height: Int) {
        let renderer = try renderer(device: device)
        renderer.planner.margins = margins
        let width = Self.cols * Self.cellWidth + Int(margins.left + margins.right)
        let height = Self.rows * Self.cellHeight + Int(margins.top + margins.bottom)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = renderer.clearColor
        let stats = renderer.render(
            frame: frame,
            viewport: TerminalMetalViewport(
                drawableWidth: Float(width), drawableHeight: Float(height), backingScale: 1,
                verticalPixelOffset: margins.top, horizontalPixelOffset: margins.left
            ),
            descriptor: pass,
            waitUntilCompleted: true
        )
        XCTAssertTrue(stats.isRenderable)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return (Pixels(width: width, bytes: bytes), width, height)
    }

    private func rgb(_ c: (UInt8, UInt8, UInt8)) -> [UInt8] { [c.0, c.1, c.2] }

    // MARK: - Padding

    func testTheGridSitsInsideThePaddingAndTheMarginsExtendItsEdges() throws {
        let margins = TerminalMetalMargins(left: 6, top: 5, right: 4, bottom: 3, fill: .extend)
        let (px, width, height) = try render(frame(), margins: margins, device: try device())
        let gridX = 6, gridY = 5
        // Row 0 starts at the padding, not at the view's corner.
        XCTAssertEqual(px.at(gridX + 4, gridY + 8), rgb(Self.rowColors[0]))
        XCTAssertEqual(px.at(gridX + 4, gridY + Self.cellHeight + 8), rgb(Self.rowColors[1]))
        // Side margins take their row's edge cells.
        XCTAssertEqual(px.at(2, gridY + 8), rgb(Self.rowColors[0]), "left margin")
        XCTAssertEqual(px.at(width - 2, gridY + 3 * Self.cellHeight + 8), rgb(Self.rowColors[3]), "right margin")
        // Top and bottom take the edge rows, which have no default cell.
        XCTAssertEqual(px.at(gridX + 4, 2), rgb(Self.rowColors[0]), "top margin")
        XCTAssertEqual(px.at(gridX + 4, height - 1), rgb(Self.rowColors[3]), "bottom margin")
        // The corners stay the view's background.
        XCTAssertEqual(px.at(1, 1), rgb(Self.defaultBackground), "corner")
    }

    func testBackgroundPaddingLeavesTheMarginsAlone() throws {
        let margins = TerminalMetalMargins(left: 6, top: 5, right: 4, bottom: 3, fill: .background)
        let (px, _, height) = try render(frame(), margins: margins, device: try device())
        XCTAssertEqual(px.at(6 + 4, 5 + 8), rgb(Self.rowColors[0]))
        XCTAssertEqual(px.at(2, 5 + 8), rgb(Self.defaultBackground))
        XCTAssertEqual(px.at(6 + 4, 2), rgb(Self.defaultBackground))
        XCTAssertEqual(px.at(6 + 4, height - 1), rgb(Self.defaultBackground))
    }

    /// A row with a default-background cell -- a prompt, typically -- is not
    /// extended above the grid by `extend`, and is by `extend-always`.
    func testExtendKeepsAPromptLikeRowOutOfTheTopMargin() throws {
        let row0 = [Self.rowColors[0], Self.defaultBackground, Self.rowColors[0], Self.rowColors[0]]
        let extend = try render(frame(row0: row0),
                                margins: TerminalMetalMargins(left: 6, top: 5, fill: .extend),
                                device: try device())
        XCTAssertEqual(extend.0.at(6 + 4, 2), rgb(Self.defaultBackground))
        XCTAssertEqual(extend.0.at(2, 5 + 8), rgb(Self.rowColors[0]), "the side still extends")

        let always = try render(frame(row0: row0),
                                margins: TerminalMetalMargins(left: 6, top: 5, fill: .extendAlways),
                                device: try device())
        XCTAssertEqual(always.0.at(6 + 4, 2), rgb(Self.rowColors[0]))
    }

    // MARK: - Selection

    private let selectFirstTwo = FfiSelectionRange(startRow: 0, startCol: 0, endRow: 0, endCol: 1, mode: .linear)

    /// Glyph colours by column on row 0, from the planned instances.
    private func row0GlyphColors(_ planner: TerminalMetalFramePlanner) -> [Int: SIMD4<Float>] {
        var colors: [Int: SIMD4<Float>] = [:]
        for glyph in planner.glyphInstances where glyph.destRect.y < Float(Self.cellHeight) {
            let col = Int(glyph.destRect.x) / Self.cellWidth
            colors[col] = glyph.color
        }
        return colors
    }

    func testSelectionForegroundColoursOnlyTheSelectedText() throws {
        let renderer = try renderer(device: try device())
        let red = TerminalMetalColor.rgba(r: 255, g: 0, b: 0)
        renderer.planner.palette.selectionForeground = red
        let viewport = TerminalMetalViewport(drawableWidth: 32, drawableHeight: 64)
        renderer.planner.plan(frame: frame(inked: true, selection: selectFirstTwo), viewport: viewport)

        let colors = row0GlyphColors(renderer.planner)
        XCTAssertEqual(colors[0], red)
        XCTAssertEqual(colors[1], red)
        XCTAssertNotEqual(colors[2], red, "an unselected cell keeps its own foreground")
        XCTAssertFalse(renderer.planner.selectionInstances.isEmpty, "the selection colour is still laid over it")

        // The rows are cached; moving the selection must replan them.
        let moved = FfiSelectionRange(startRow: 0, startCol: 2, endRow: 0, endCol: 3, mode: .linear)
        renderer.planner.plan(frame: frame(inked: true, selection: moved), viewport: viewport)
        let after = row0GlyphColors(renderer.planner)
        XCTAssertNotEqual(after[0], red)
        XCTAssertEqual(after[2], red)
    }

    func testInvertedSelectionSwapsEachCellsColoursWithNoOverlay() throws {
        let renderer = try renderer(device: try device())
        renderer.planner.palette.selectionInvertsColors = true
        renderer.planner.plan(frame: frame(inked: true, selection: selectFirstTwo),
                              viewport: TerminalMetalViewport(drawableWidth: 32, drawableHeight: 64))

        XCTAssertTrue(renderer.planner.selectionInstances.isEmpty)
        let row0Background = TerminalMetalColor.rgba(r: 200, g: 0, b: 0)
        let white = TerminalMetalColor.premultiplied(TerminalMetalColor.rgba(r: 255, g: 255, b: 255))
        let colors = row0GlyphColors(renderer.planner)
        XCTAssertEqual(colors[0], TerminalMetalColor.premultiplied(row0Background), "text takes the background")
        XCTAssertEqual(colors[2], white, "an unselected cell is untouched")
        let invertedBackground = renderer.planner.backgroundInstances.contains { instance in
            let rect: SIMD4<Float> = instance.rect
            return rect.x == 0 && rect.y == 0 && instance.color == white
        }
        XCTAssertTrue(invertedBackground, "the selected cells' background is their foreground")
    }

    // MARK: - window-colorspace

    func testDisplayP3ValuesAreDrawnAsTheyAreInsteadOfConverted() throws {
        let renderer = try renderer(device: try device())
        renderer.planner.colorSpace = .displayP3
        let cell = TerminalFrame(packed: Data(packedCell(bg: (255, 0, 0))), cols: 1, rows: 1).row(0)[0]

        let converted = renderer.planner.backgroundColor(of: cell)
        XCTAssertGreaterThan(converted.y, 0.1, "sRGB red expressed in P3 has green in it")

        renderer.planner.cellColorsAreDisplayP3 = true
        XCTAssertEqual(renderer.planner.backgroundColor(of: cell), SIMD4<Float>(1, 0, 0, 1))
    }
}
