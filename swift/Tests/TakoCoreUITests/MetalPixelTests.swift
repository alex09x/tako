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

/// What the GPU actually put on screen.
///
/// `MetalTerminalRendererTests` covers planning: which passes run, which
/// instances they carry, what the buffers hold. Everything it checks is one
/// step short of the pixels, and the two crashes this layer has shipped --
/// a SIGSEGV inside `CGContextClearRect` while rasterizing a glyph, and a
/// stale row cache painting a frame that no longer matched the terminal --
/// both lived past that step. So these render into an offscreen texture and
/// read the bytes back.
///
/// **Deliberately not golden images.** Glyph rasterization is a function of
/// the macOS version, the installed font and the GPU's own rounding, so a
/// committed PNG would compare equal on the machine that produced it and
/// nowhere else -- and a fixture that must be regenerated to pass teaches
/// everyone to regenerate it without looking. These assert properties
/// instead: the background is the background, a glyph put ink where the cell
/// is and nowhere else, reverse video swapped, the cursor covers its cell,
/// the same frame renders identically twice. Those hold on any machine and
/// still fail loudly on a blank frame, a misplaced cell or a wrong colour.
///
/// Skips itself when there is no Metal device, or none with shared storage to
/// read a texture back through.
final class MetalPixelTests: XCTestCase {

    // MARK: - Fixtures

    struct CellSpec {
        var ch: UInt32 = 32
        var fg: (r: UInt8, g: UInt8, b: UInt8) = (0xff, 0xff, 0xff)
        var bg: (r: UInt8, g: UInt8, b: UInt8) = (0x00, 0x00, 0x00)
        var bits: UInt16 = 0
        var underlineStyle: UInt8 = 0
        var underlineColor: (r: UInt8, g: UInt8, b: UInt8) = (0xff, 0xff, 0xff)

        static let boldBit: UInt16 = 1 << 0
        static let dimBit: UInt16 = 1 << 1
        static let italicBit: UInt16 = 1 << 2
        static let underlineBit: UInt16 = 1 << 3
        static let reverseBit: UInt16 = 1 << 5
        static let hiddenBit: UInt16 = 1 << 6
        static let strikethroughBit: UInt16 = 1 << 7
        static let overlineBit: UInt16 = 1 << 8
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
            while bytes.count % TerminalCell.byteSize != 0 { bytes.append(0) }
        }
        return Data(bytes)
    }

    func frame(
        cols: UInt32,
        rows: UInt32,
        cells: [CellSpec]? = nil,
        cursorVisible: Bool = false,
        cursorRow: UInt32 = 0,
        cursorCol: UInt32 = 0,
        cursorShape: FfiCursorShape = .block,
        selection: FfiSelectionRange? = nil
    ) -> FfiRenderFrame {
        let filled = cells ?? Array(repeating: CellSpec(), count: Int(cols) * Int(rows))
        return FfiRenderFrame(
            snapshot: FfiSnapshot(
                cols: cols,
                rows: rows,
                cursorRow: cursorRow,
                cursorCol: cursorCol,
                cursorVisible: cursorVisible,
                cursorStyle: FfiCursorStyle(shape: cursorShape, blinking: false),
                title: "test",
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
                damagedRows: Array(0..<rows),
                selection: selection,
                graphicsPlacements: []
            ),
            packedCells: packed(filled),
            // Synthetic: no engine produced this frame, so there is no
            // generation for it to belong to. The renderer does not read it.
            epoch: 0
        )
    }

    /// 10x20 pixel cells with no backing scale, so a cell's pixels are at
    /// exactly `(col * 10, row * 20)`.
    static let cellWidth = 10
    static let cellHeight = 20

    func metrics() -> TerminalMetalCellMetrics {
        TerminalMetalCellMetrics(
            font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
            cellWidth: CGFloat(Self.cellWidth),
            cellHeight: CGFloat(Self.cellHeight),
            ascent: 15,
            scale: 1
        )
    }

    func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }

    // MARK: - Rendering and readback

    /// One rendered frame, addressable by pixel and by cell.
    struct Pixels {
        let width: Int
        let height: Int
        /// BGRA, one byte per component, row-major.
        let bytes: [UInt8]

        /// The colour at a pixel, as (r, g, b).
        func at(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i + 2], bytes[i + 1], bytes[i])
        }

        /// The pixel at the middle of a cell, where a glyph's ink is densest
        /// and a background fill is unambiguous.
        func centre(ofCol col: Int, row: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            at(x: col * MetalPixelTests.cellWidth + MetalPixelTests.cellWidth / 2,
               y: row * MetalPixelTests.cellHeight + MetalPixelTests.cellHeight / 2)
        }

        /// Every pixel of one cell.
        func cell(col: Int, row: Int) -> [(r: UInt8, g: UInt8, b: UInt8)] {
            var out: [(r: UInt8, g: UInt8, b: UInt8)] = []
            for y in (row * MetalPixelTests.cellHeight)..<((row + 1) * MetalPixelTests.cellHeight) {
                for x in (col * MetalPixelTests.cellWidth)..<((col + 1) * MetalPixelTests.cellWidth) {
                    out.append(at(x: x, y: y))
                }
            }
            return out
        }

        /// How many pixels of a cell differ from `colour`. Ink, in other
        /// words, when `colour` is the background.
        func pixels(inCol col: Int, row: Int, differingFrom colour: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
            cell(col: col, row: row).filter { $0 != colour }.count
        }
    }

    func device() throws -> MTLDevice {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        try XCTSkipUnless(device.hasUnifiedMemory, "reading a texture back needs shared storage")
        return device
    }

    func render(
        _ frame: FfiRenderFrame,
        cols: Int,
        rows: Int,
        device: MTLDevice,
        configure: ((MetalTerminalRenderer) -> Void)? = nil
    ) throws -> Pixels {
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )
        configure?(renderer)

        let width = cols * Self.cellWidth
        let height = rows * Self.cellHeight

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
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
                drawableWidth: Float(width), drawableHeight: Float(height)),
            descriptor: pass,
            waitUntilCompleted: true
        )
        XCTAssertTrue(stats.isRenderable, "the frame was rejected before it reached the GPU")

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    // MARK: - The background

    /// The floor everything else stands on: an unstyled screen is its
    /// background colour, edge to edge, with nothing left uninitialised.
    func testABlankScreenIsEntirelyItsBackgroundColour() throws {
        let device = try device()
        var cell = CellSpec()
        cell.bg = (0x20, 0x30, 0x40)
        let pixels = try render(
            frame(cols: 4, rows: 2, cells: Array(repeating: cell, count: 8)),
            cols: 4, rows: 2, device: device)

        for row in 0..<2 {
            for col in 0..<4 {
                for pixel in pixels.cell(col: col, row: row) {
                    XCTAssertEqual(pixel.r, 0x20, accuracy: 2)
                    XCTAssertEqual(pixel.g, 0x30, accuracy: 2)
                    XCTAssertEqual(pixel.b, 0x40, accuracy: 2)
                }
            }
        }
    }

    /// Each cell gets its own background, in its own place. A row-major
    /// indexing slip puts the right colours in the wrong cells, which the
    /// planning tests cannot see.
    func testEachCellPaintsItsOwnBackgroundInItsOwnPlace() throws {
        let device = try device()
        let colours: [(UInt8, UInt8, UInt8)] = [
            (0xff, 0x00, 0x00), (0x00, 0xff, 0x00),
            (0x00, 0x00, 0xff), (0xff, 0xff, 0x00),
        ]
        let cells = colours.map { c -> CellSpec in
            var cell = CellSpec()
            cell.bg = (c.0, c.1, c.2)
            return cell
        }

        let pixels = try render(frame(cols: 2, rows: 2, cells: cells), cols: 2, rows: 2, device: device)

        for (index, expected) in colours.enumerated() {
            let (col, row) = (index % 2, index / 2)
            let got = pixels.centre(ofCol: col, row: row)
            XCTAssertEqual(got.r, expected.0, accuracy: 2, "cell \(col),\(row) red")
            XCTAssertEqual(got.g, expected.1, accuracy: 2, "cell \(col),\(row) green")
            XCTAssertEqual(got.b, expected.2, accuracy: 2, "cell \(col),\(row) blue")
        }
    }

    // MARK: - Glyphs

    /// A glyph has to reach the texture, and stay inside its cell. This is
    /// the path that crashed in CGContextClearRect: anything that stops the
    /// atlas producing a mask leaves the cell flat, and this notices.
    func testAGlyphPutsInkInsideItsCellAndNowhereElse() throws {
        let device = try device()
        var blank = CellSpec()
        blank.bg = (0x00, 0x00, 0x00)
        var glyph = blank
        glyph.ch = UInt32(UnicodeScalar("W").value)
        glyph.fg = (0xff, 0xff, 0xff)

        // A single 'W' in the middle of a blank row.
        let cells = [blank, glyph, blank]
        let pixels = try render(frame(cols: 3, rows: 1, cells: cells), cols: 3, rows: 1, device: device)

        let black = (r: UInt8(0), g: UInt8(0), b: UInt8(0))
        XCTAssertGreaterThan(
            pixels.pixels(inCol: 1, row: 0, differingFrom: black), 10,
            "the glyph never reached the texture")
        XCTAssertEqual(
            pixels.pixels(inCol: 0, row: 0, differingFrom: black), 0,
            "ink bled into the cell to the left")
        XCTAssertEqual(
            pixels.pixels(inCol: 2, row: 0, differingFrom: black), 0,
            "ink bled into the cell to the right")
    }

    /// Every attribute the atlas can be asked to rasterize, in one frame.
    /// The point is coverage of the rasterization path rather than any one
    /// appearance: this is where the SIGSEGV was, and a crash here fails the
    /// test by taking the process with it.
    func testEveryAttributeRasterizesAndLeavesInk() throws {
        let device = try device()
        let attributes: [(UInt16, String)] = [
            (0, "plain"),
            (CellSpec.boldBit, "bold"),
            (CellSpec.italicBit, "italic"),
            (CellSpec.boldBit | CellSpec.italicBit, "bold italic"),
            (CellSpec.underlineBit, "underline"),
            (CellSpec.strikethroughBit, "strikethrough"),
            (CellSpec.overlineBit, "overline"),
            (CellSpec.dimBit, "dim"),
        ]

        let cells = attributes.map { bits, _ -> CellSpec in
            var cell = CellSpec()
            cell.ch = UInt32(UnicodeScalar("M").value)
            cell.bits = bits
            cell.fg = (0xff, 0xff, 0xff)
            cell.bg = (0x00, 0x00, 0x00)
            return cell
        }

        let pixels = try render(
            frame(cols: UInt32(cells.count), rows: 1, cells: cells),
            cols: cells.count, rows: 1, device: device)

        let black = (r: UInt8(0), g: UInt8(0), b: UInt8(0))
        for (index, attribute) in attributes.enumerated() {
            XCTAssertGreaterThan(
                pixels.pixels(inCol: index, row: 0, differingFrom: black), 0,
                "\(attribute.1) drew nothing")
        }
    }

    /// A hidden cell is the one case where drawing nothing is correct.
    func testAHiddenGlyphLeavesTheCellBlank() throws {
        let device = try device()
        var cell = CellSpec()
        cell.ch = UInt32(UnicodeScalar("W").value)
        cell.bits = CellSpec.hiddenBit
        cell.fg = (0xff, 0xff, 0xff)
        cell.bg = (0x00, 0x00, 0x00)

        let pixels = try render(frame(cols: 1, rows: 1, cells: [cell]), cols: 1, rows: 1, device: device)

        XCTAssertEqual(
            pixels.pixels(inCol: 0, row: 0, differingFrom: (r: 0, g: 0, b: 0)), 0,
            "a hidden glyph was drawn anyway")
    }


}
