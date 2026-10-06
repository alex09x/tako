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
import ImageIO
import XCTest
@testable import TakoCoreUI

final class TerminalRendererCoverageTests: XCTestCase {

    // MARK: - Helpers

    final class BitmapContext {
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

    func assertColorApprox(
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

    func makeCell(
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

    func makeCellWithScalar(
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


}
