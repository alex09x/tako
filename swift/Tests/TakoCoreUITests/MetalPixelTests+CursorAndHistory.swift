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
import Metal
import XCTest
@testable import TakoCoreUI

extension MetalPixelTests {
    // MARK: - Reverse video

    /// Reverse video is a swap, and the cheapest way to see it is that the
    /// cell's own background changed colour -- the corners of a cell hold
    /// background whatever glyph is in it.
    func testReverseVideoSwapsTheCellBackgroundForItsForeground() throws {
        let device = try device()
        var plain = CellSpec()
        plain.ch = UInt32(UnicodeScalar("A").value)
        plain.fg = (0xff, 0x00, 0x00)
        plain.bg = (0x00, 0x00, 0xff)
        var reversed = plain
        reversed.bits = CellSpec.reverseBit

        let pixels = try render(
            frame(cols: 2, rows: 1, cells: [plain, reversed]), cols: 2, rows: 1, device: device)

        // Top-left corner of each cell: background, never glyph.
        let plainCorner = pixels.at(x: 0, y: 0)
        let reversedCorner = pixels.at(x: Self.cellWidth, y: 0)

        XCTAssertEqual(plainCorner.b, 0xff, accuracy: 2, "plain cell lost its blue background")
        XCTAssertEqual(reversedCorner.r, 0xff, accuracy: 2, "reversed cell did not take the foreground")
        XCTAssertLessThan(reversedCorner.b, 0x40, "reversed cell kept its old background")
    }

    // MARK: - The cursor

    /// A block cursor covers its cell and only its cell. "Where is my
    /// cursor" is the single most visible thing this renderer does.
    func testABlockCursorCoversItsOwnCell() throws {
        let device = try device()
        var cell = CellSpec()
        cell.bg = (0x00, 0x00, 0x00)
        let cells = Array(repeating: cell, count: 6)

        let plain = try render(frame(cols: 3, rows: 2, cells: cells), cols: 3, rows: 2, device: device)
        let withCursor = try render(
            frame(cols: 3, rows: 2, cells: cells,
                  cursorVisible: true, cursorRow: 1, cursorCol: 2),
            cols: 3, rows: 2, device: device)

        let black = (r: UInt8(0), g: UInt8(0), b: UInt8(0))
        XCTAssertEqual(
            plain.pixels(inCol: 2, row: 1, differingFrom: black), 0,
            "something was already drawn where the cursor goes")
        XCTAssertGreaterThan(
            withCursor.pixels(inCol: 2, row: 1, differingFrom: black),
            Self.cellWidth * Self.cellHeight / 2,
            "the block cursor did not fill its cell")

        for (col, row) in [(0, 0), (1, 0), (2, 0), (0, 1), (1, 1)] {
            XCTAssertEqual(
                withCursor.pixels(inCol: col, row: row, differingFrom: black), 0,
                "the cursor leaked into cell \(col),\(row)")
        }
    }

    /// An invisible cursor draws nothing, which is what makes hiding it work.
    func testAnInvisibleCursorDrawsNothing() throws {
        let device = try device()
        var cell = CellSpec()
        cell.bg = (0x00, 0x00, 0x00)
        let pixels = try render(
            frame(cols: 2, rows: 1, cells: [cell, cell],
                  cursorVisible: false, cursorRow: 0, cursorCol: 1),
            cols: 2, rows: 1, device: device)

        XCTAssertEqual(
            pixels.pixels(inCol: 1, row: 0, differingFrom: (r: 0, g: 0, b: 0)), 0)
    }

    // MARK: - Determinism

    /// The same frame must produce the same pixels. A renderer that carries
    /// state between frames -- a row cache, an atlas page, a reused buffer --
    /// is exactly how a stale frame reaches the screen, which is the other
    /// bug this layer shipped.
    func testTheSameFrameRendersToTheSamePixelsTwice() throws {
        let device = try device()
        let cells = "hello world".enumerated().map { _, character -> CellSpec in
            var cell = CellSpec()
            cell.ch = character.unicodeScalars.first!.value
            cell.fg = (0xff, 0xff, 0xff)
            cell.bg = (0x10, 0x10, 0x10)
            return cell
        }

        let first = try render(
            frame(cols: UInt32(cells.count), rows: 1, cells: cells),
            cols: cells.count, rows: 1, device: device)
        let second = try render(
            frame(cols: UInt32(cells.count), rows: 1, cells: cells),
            cols: cells.count, rows: 1, device: device)

        XCTAssertEqual(first.bytes, second.bytes, "two renders of one frame disagreed")
    }

    /// Rendering a second, different frame through the *same* renderer must
    /// show the second frame. The row cache replans only damaged rows, and
    /// a frame that reports every row damaged has to be honoured in full.
    func testASecondFrameThroughOneRendererReplacesTheFirst() throws {
        let device = try device()
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )

        func draw(bg: (UInt8, UInt8, UInt8)) throws -> Pixels {
            var cell = CellSpec()
            cell.bg = bg
            let width = 2 * Self.cellWidth
            let height = Self.cellHeight

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

            _ = renderer.render(
                frame: frame(cols: 2, rows: 1, cells: [cell, cell]),
                viewport: TerminalMetalViewport(
                    drawableWidth: Float(width), drawableHeight: Float(height)),
                descriptor: pass,
                waitUntilCompleted: true)

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

        _ = try draw(bg: (0xff, 0x00, 0x00))
        let second = try draw(bg: (0x00, 0xff, 0x00))

        let centre = second.centre(ofCol: 0, row: 0)
        XCTAssertEqual(centre.g, 0xff, accuracy: 2, "the second frame did not reach the texture")
        XCTAssertLessThan(centre.r, 0x40, "the first frame was still on screen")
    }

    func testClaudeAlternateScreenHistorySwipesAndReverseRestorationPixels() throws {
        let device = try device()
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )

        let cols = 80
        let rows = 53
        let width = cols * Self.cellWidth
        let height = rows * Self.cellHeight

        func renderFrame(_ f: FfiRenderFrame) throws -> Pixels {
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
                frame: f,
                viewport: TerminalMetalViewport(
                    drawableWidth: Float(width), drawableHeight: Float(height)),
                descriptor: pass,
                waitUntilCompleted: true)
            XCTAssertTrue(stats.isRenderable)

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

        func makeCells(lines: [String]) -> [CellSpec] {
            var out: [CellSpec] = []
            for line in lines {
                for scalar in line.unicodeScalars {
                    out.append(CellSpec(ch: scalar.value, fg: (0xff, 0xff, 0xff), bg: (0x00, 0x00, 0x00)))
                }
            }
            return out
        }

        // 1. Initial 53-row portrait Claude-like alternate-screen transcript containing numbered rows 1 through 30
        var tailLines = (1...30).map { i -> String in
            let word: String
            switch i {
            case 27: word = "twenty-seven"
            case 28: word = "twenty-eight"
            case 29: word = "twenty-nine"
            case 30: word = "thirty"
            default: word = "line-\(i)"
            }
            let text = "\(i) \(word)"
            return text.padding(toLength: cols, withPad: " ", startingAt: 0)
        }
        while tailLines.count < rows {
            tailLines.append(String(repeating: " ", count: cols))
        }

        let f0 = frame(
            cols: UInt32(cols),
            rows: UInt32(rows),
            cells: makeCells(lines: tailLines)
        )
        _ = try renderFrame(f0)

        // 2. History frame
        var historyLines = (1...30).map { i -> String in
            let word: String
            switch i {
            case 27: word = "twenty-seven"
            case 28: word = "twenty-eight"
            case 29: word = "twenty-nine"
            case 30: word = "thirty"
            default: word = "hist-\(i)"
            }
            let text = "  \(word)"
            return text.padding(toLength: cols, withPad: " ", startingAt: 0)
        }
        while historyLines.count < rows {
            historyLines.append(String(repeating: " ", count: cols))
        }

        let f1 = frame(
            cols: UInt32(cols),
            rows: UInt32(rows),
            cells: makeCells(lines: historyLines)
        )
        _ = try renderFrame(f1)

        // 3. Intermediate frame
        var interLines = historyLines
        interLines[26] = "27twenty-seven".padding(toLength: cols, withPad: " ", startingAt: 0)
        interLines[27] = "28twenty-eight".padding(toLength: cols, withPad: " ", startingAt: 0)
        interLines[28] = "29twenty-nine".padding(toLength: cols, withPad: " ", startingAt: 0)
        interLines[29] = "30thirty".padding(toLength: cols, withPad: " ", startingAt: 0)

        var fInter = frame(
            cols: UInt32(cols),
            rows: UInt32(rows),
            cells: makeCells(lines: interLines)
        )
        fInter.snapshot.damagedRows = [26, 27, 28, 29]
        _ = try renderFrame(fInter)

        // 4. Restored tail: row 27-30 only have "27", "28", "29", "30" followed by spaces
        var restoredTailLines = tailLines
        restoredTailLines[26] = "27".padding(toLength: cols, withPad: " ", startingAt: 0)
        restoredTailLines[27] = "28".padding(toLength: cols, withPad: " ", startingAt: 0)
        restoredTailLines[28] = "29".padding(toLength: cols, withPad: " ", startingAt: 0)
        restoredTailLines[29] = "30".padding(toLength: cols, withPad: " ", startingAt: 0)

        var fRestored = frame(
            cols: UInt32(cols),
            rows: UInt32(rows),
            cells: makeCells(lines: restoredTailLines)
        )
        fRestored.snapshot.damagedRows = [0]
        let pixels = try renderFrame(fRestored)

        let black = (r: UInt8(0), g: UInt8(0), b: UInt8(0))
        // In row 26 (line 27), cols 0..1 have "27", but cols 2..13 MUST BE SPACES (no ink pixels)
        for col in 2..<14 {
            XCTAssertEqual(
                pixels.pixels(inCol: col, row: 26, differingFrom: black),
                0,
                "Row 26 col \(col) retained stale ink from twenty-seven"
            )
        }
    }
}

}
