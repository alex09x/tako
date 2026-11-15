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
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TakoCoreUI

/// An OSC 1337 inline image sized by the program, carried end to end: the
/// engine stores a real PNG, the decoders read it back at the size it is
/// encoded at, and the layout draws all of it at the size asked for.
final class InlineImageSizingTests: XCTestCase {
    private static let cell = CGSize(width: 10, height: 20)

    /// A real `width` x `height` PNG.
    private func png(width: Int, height: Int) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Sends the image with `args` on an 80x24 grid of 10x20 px cells and
    /// returns what a renderer gets: the stored image, its decoded size, the
    /// layout, and the row the cursor went to.
    private func place(_ args: String, width: Int = 100, height: Int = 50) throws
        -> (stored: FfiStoredImage, decoded: Int, layout: TerminalImageLayout, row: UInt32) {
        let core = TakoCore(cols: 80, rows: 24)
        core.setPixelSize(widthPx: 800, heightPx: 480)
        let data = try png(width: width, height: height).base64EncodedString()
        core.feed(bytes: Data("\u{1b}[H\u{1b}]1337;File=\(args):\(data)\u{07}".utf8))
        let placement = try XCTUnwrap(core.graphicsPlacements().last, "the image is placed")
        let stored = try XCTUnwrap(core.graphicsImage(imageId: placement.imageId))
        // What the Metal path does first: decode at the stored size.
        let decoded = try MetalImageCache.decodePNG(imageId: placement.imageId, width: Int(stored.width),
                                                      height: Int(stored.height), pixels: stored.pixels)
        let layout = try XCTUnwrap(TerminalImageLayout.resolve(
            placement, image: CGSize(width: Int(stored.width), height: Int(stored.height)), cell: Self.cell))
        return (stored, decoded.count, layout, core.cursorRow())
    }

    func testAHeightInCellsDrawsTheWholeImageScaledUpByItsRatio() throws {
        let got = try place("inline=1;height=3")
        XCTAssertEqual(got.decoded, 100 * 50 * 4, "decoded at the size it is encoded at")
        XCTAssertEqual(got.layout.source, CGRect(x: 0, y: 0, width: 100, height: 50), "all of it, not a crop")
        XCTAssertEqual(got.layout.destination.size, CGSize(width: 120, height: 60))
        XCTAssertEqual(got.row, 3)
    }

    func testAWidthInCellsDrawsTheWholeImageScaledDownByItsRatio() throws {
        let got = try place("inline=1;width=5")
        XCTAssertEqual(got.decoded, 100 * 50 * 4)
        XCTAssertEqual(got.layout.source, CGRect(x: 0, y: 0, width: 100, height: 50), "all of it, not a crop")
        XCTAssertEqual(got.layout.destination.size, CGSize(width: 50, height: 25))
        XCTAssertEqual(got.row, 2, "25 px is 2 rows of 20")
    }

    func testTwoSidesFitTheWholeImageCentredInTheBox() throws {
        let got = try place("inline=1;width=40;height=5")
        XCTAssertEqual(got.decoded, 100 * 50 * 4)
        XCTAssertEqual(got.layout.source, CGRect(x: 0, y: 0, width: 100, height: 50))
        // A 400x100 box: the height limits the 2:1 image to 200x100, centred across.
        XCTAssertEqual(got.layout.destination, CGRect(x: 100, y: 0, width: 200, height: 100))
        XCTAssertEqual(got.row, 5, "below the whole box")
    }

    func testPixelsAreTakenToTheNearestWholeCell() throws {
        // 305 px on 10 px cells is 31 cells: drawn 310 px wide, 155 high, 8 rows.
        let got = try place("inline=1;width=305px")
        XCTAssertEqual(got.decoded, 100 * 50 * 4)
        XCTAssertEqual(got.layout.destination.size, CGSize(width: 310, height: 155))
        XCTAssertEqual(got.row, 8)
    }

    func testTheBoxSurvivesACheckpointAndStillDecodes() throws {
        let core = TakoCore(cols: 80, rows: 24)
        core.setPixelSize(widthPx: 800, heightPx: 480)
        let data = try png(width: 100, height: 50).base64EncodedString()
        core.feed(bytes: Data("\u{1b}]1337;File=inline=1;height=3:\(data)\u{07}".utf8))
        let restored = TakoCore(cols: 80, rows: 24)
        XCTAssertTrue(restored.restore(bytes: core.checkpoint()))
        let placement = try XCTUnwrap(restored.graphicsPlacements().last)
        XCTAssertEqual(placement.columns, 0)
        XCTAssertEqual(placement.rows, 3)
        let stored = try XCTUnwrap(restored.graphicsImage(imageId: placement.imageId))
        XCTAssertEqual(try MetalImageCache.decodePNG(imageId: placement.imageId, width: Int(stored.width),
                                                     height: Int(stored.height), pixels: stored.pixels).count,
                       100 * 50 * 4)
    }

    func testATallImageIsHeldToTheRowCap() throws {
        // 20 columns would draw a 10x2000 image 200x40000, 2000 rows; the box is
        // held to 1024 rows, 20480 px, and the whole image fitted inside it.
        let got = try place("inline=1;width=20", width: 10, height: 2000)
        XCTAssertEqual(got.decoded, 10 * 2000 * 4)
        XCTAssertEqual(got.layout.source, CGRect(x: 0, y: 0, width: 10, height: 2000))
        XCTAssertEqual(got.layout.destination.height, 20480, accuracy: 0.001)
        XCTAssertEqual(got.layout.destination.width, 102.4, accuracy: 0.001)
        XCTAssertLessThanOrEqual(got.layout.destination.maxY, 1024 * Self.cell.height + 0.001)
        XCTAssertEqual(got.row, 23)
    }

    func testNoSizeDrawsTheImageAtItsOwnSize() throws {
        let got = try place("inline=1")
        XCTAssertEqual(got.decoded, 100 * 50 * 4)
        XCTAssertEqual(got.layout.destination.size, CGSize(width: 100, height: 50))
        XCTAssertEqual(got.row, 3)
    }
}
