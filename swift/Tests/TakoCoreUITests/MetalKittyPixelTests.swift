/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import XCTest
@testable import TakoCoreUI

extension MetalPixelTests {
    func testKittyImageReachesMetalPixelsAtItsRequestedPlacement() throws {
        let device = try device()
        var frame = frame(cols: 4, rows: 2)
        frame.snapshot.graphicsPlacements = [FfiGraphicsPlacement(imageId: 1, placementId: 0, row: 0, col: 0,
                                                                   columns: 2, rows: 1, offsetX: 2, offsetY: 3)]
        let pixel = [UInt8](arrayLiteral: 255, 0, 255, 255)
        let image = FfiStoredImage(format: .rgba, width: 4, height: 4,
                                   pixels: Data(Array(repeating: pixel, count: 16).flatMap { $0 }))
        let result = try render(frame, cols: 4, rows: 2, device: device) { renderer in
            renderer.imageProvider = { id in id == 1 ? image : nil }
        }
        let inside = result.at(x: 10, y: 10), outside = result.at(x: 0, y: 0)
        XCTAssertGreaterThan(inside.r, 200)
        XCTAssertLessThan(inside.g, 30)
        XCTAssertGreaterThan(inside.b, 200)
        XCTAssertLessThan(outside.r, 30)
        XCTAssertLessThan(outside.b, 30)
    }

    func testKittyImagePartiallyInScrollbackIsClippedRatherThanRescaled() throws {
        let device = try device()
        var frame = frame(cols: 4, rows: 2)
        frame.snapshot.graphicsPlacements = [FfiGraphicsPlacement(imageId: 1, placementId: 0, row: 0, col: 0,
                                                                   columns: 1, rows: 2, rowOffset: -1)]
        let pixel = [UInt8](arrayLiteral: 255, 0, 255, 255)
        let image = FfiStoredImage(format: .rgba, width: 4, height: 16,
                                   pixels: Data(Array(repeating: pixel, count: 64).flatMap { $0 }))
        let result = try render(frame, cols: 4, rows: 2, device: device) { renderer in
            renderer.imageProvider = { id in id == 1 ? image : nil }
        }
        let visible = result.at(x: 5, y: 5), below = result.at(x: 5, y: 25)
        XCTAssertGreaterThan(visible.r, 200)
        XCTAssertGreaterThan(visible.b, 200)
        XCTAssertLessThan(below.r, 30)
        XCTAssertLessThan(below.b, 30)
    }

    func testKittyRegionClipsImageAtBothEdgesWithoutRescaling() throws {
        let device = try device()
        var frame = frame(cols: 4, rows: 4)
        frame.snapshot.graphicsPlacements = [FfiGraphicsPlacement(imageId: 1, placementId: 0, row: 0, col: 0,
                                                                   columns: 1, rows: 4, clipTopRows: 1, clipBottomRows: 1)]
        let bands: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255]]
        let pixels = (0..<32).flatMap { y in Array(repeating: bands[y / 8], count: 4).flatMap { $0 } }
        let image = FfiStoredImage(format: .rgba, width: 4, height: 32, pixels: Data(pixels))
        let result = try render(frame, cols: 4, rows: 4, device: device) { renderer in
            renderer.imageProvider = { id in id == 1 ? image : nil }
        }
        let above = result.at(x: 5, y: 5), upper = result.at(x: 5, y: 30)
        let lower = result.at(x: 5, y: 50), below = result.at(x: 5, y: 70)
        XCTAssertLessThan(above.r, 30)
        XCTAssertGreaterThan(upper.g, 200)
        XCTAssertLessThan(upper.r, 30)
        XCTAssertGreaterThan(lower.b, 200)
        XCTAssertLessThan(lower.r, 30)
        XCTAssertLessThan(below.r, 30)
    }
}
