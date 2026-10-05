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
import CoreGraphics
import ImageIO
import XCTest
@testable import TakoCoreUI

final class MetalImageCacheTests: XCTestCase {

    func testRGBConversionPreservesBGRAChannelOrder() throws {
        let image = FfiStoredImage(
            format: .rgb,
            width: 2,
            height: 1,
            pixels: Data([255, 0, 0, 0, 255, 0])
        )
        let upload = try MetalImageCache.decode(imageId: 1, from: image)
        XCTAssertEqual(upload.width, 2)
        XCTAssertEqual(upload.height, 1)
        XCTAssertEqual(upload.format, .rgb)
        XCTAssertEqual(upload.bgraPixels, Data([0, 0, 255, 255, 0, 255, 0, 255]))
    }

    func testRGBAConversionPremultipliesAlphaChannel() throws {
        let image = FfiStoredImage(
            format: .rgba,
            width: 1,
            height: 1,
            pixels: Data([0x20, 0x40, 0x80, 0x80])
        )
        let upload = try MetalImageCache.decode(imageId: 2, from: image)
        XCTAssertEqual(upload.format, .rgba)
        XCTAssertEqual(upload.bgraPixels, Data([0x40, 0x20, 0x10, 0x80]))
    }

    func testMalformedInputRejectedForWrongRawPixelCount() {
        let image = FfiStoredImage(
            format: .rgb,
            width: 2,
            height: 2,
            pixels: Data([0, 0, 0, 0, 0])
        )
        XCTAssertThrowsError(try MetalImageCache.decode(imageId: 3, from: image)) { error in
            guard case .invalidPixelByteCount = error as? MetalImageCacheError else {
                XCTFail("Expected invalidPixelByteCount")
                return
            }
        }
    }

    func testCacheEntryTracksContentIdentity() throws {
        let cache = MetalImageCache(device: nil)
        let green = FfiStoredImage(format: .rgb, width: 1, height: 1, pixels: Data([0, 255, 0]))
        let greenAgain = FfiStoredImage(format: .rgb, width: 1, height: 1, pixels: Data([0, 255, 0]))
        let blue = FfiStoredImage(format: .rgb, width: 1, height: 1, pixels: Data([0, 0, 255]))

        let first = try cache.cache(imageId: 9, storedImage: green)
        let second = try cache.cache(imageId: 9, storedImage: greenAgain)
        let changed = try cache.cache(imageId: 9, storedImage: blue)

        XCTAssertEqual(first.metadata, second.metadata)
        XCTAssertEqual(cache.cachedCount, 1)
        XCTAssertNotEqual(first.metadata.contentIdentity, changed.metadata.contentIdentity)
        XCTAssertEqual(changed.metadata, cache.metadata(for: 9))
        XCTAssertNil(cache.metadata(for: 1))
    }

    func testPurgeRemovesUnreferencedImages() throws {
        let cache = MetalImageCache(device: nil)
        _ = try cache.cache(imageId: 100, storedImage: FfiStoredImage(format: .rgba, width: 1, height: 1, pixels: Data([0, 0, 0, 255])))
        _ = try cache.cache(imageId: 200, storedImage: FfiStoredImage(format: .rgba, width: 1, height: 1, pixels: Data([255, 255, 255, 255])))

        XCTAssertEqual(cache.cachedCount, 2)

        let placements = [
            FfiGraphicsPlacement(imageId: 100, placementId: 1, row: 0, col: 0)
        ]
        let purged = Set(cache.purge(unusedBy: placements))
        XCTAssertEqual(purged, [200])
        XCTAssertNil(cache.metadata(for: 200))
        XCTAssertNotNil(cache.metadata(for: 100))
        XCTAssertEqual(cache.cachedCount, 1)
    }

    func testPNGConversionPreservesTopToBottomRowOrder() throws {
        // CGImage and Kitty both define the first encoded row as the top of
        // the image. Make the two rows unmistakable so a CoreGraphics bitmap
        // coordinate flip cannot hide behind a symmetric fixture.
        let rgba = Data([
            255, 0, 0, 255, // top: red
            0, 0, 255, 255, // bottom: blue
        ])
        let provider = try XCTUnwrap(CGDataProvider(data: rgba as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 1,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            encoded,
            "public.png" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let upload = try MetalImageCache.decode(
            imageId: 300,
            from: FfiStoredImage(format: .png, width: 1, height: 2, pixels: encoded as Data)
        )

        XCTAssertEqual(upload.bgraPixels, Data([
            0, 0, 255, 255, // top: red, BGRA
            255, 0, 0, 255, // bottom: blue, BGRA
        ]))
    }

    func testDecodedMemoryExceedingBudgetIsRejected() throws {
        // A tiny image structure claiming 16,384 x 16,384 (1 GiB decoded)
        let image = FfiStoredImage(
            format: .png,
            width: 16384,
            height: 16384,
            pixels: Data([0x89, 0x50, 0x4e, 0x47])
        )
        XCTAssertThrowsError(try MetalImageCache.decode(imageId: 999, from: image)) { error in
            guard case .decodedMemoryExceedsBudget(let id, let bytes, let budget) = error as? MetalImageCacheError else {
                XCTFail("Expected decodedMemoryExceedsBudget, got \(error)")
                return
            }
            XCTAssertEqual(id, 999)
            XCTAssertEqual(bytes, 16384 * 16384 * 4)
            XCTAssertEqual(budget, MetalImageCache.maxDecodedImageBytes)
        }
    }

    func testCompressedPNGExceedingDecodedBudgetIsRejected() throws {
        let oldBudget = MetalImageCache.maxDecodedImageBytes
        defer { MetalImageCache.maxDecodedImageBytes = oldBudget }
        MetalImageCache.maxDecodedImageBytes = 200

        let rgba = Data(repeating: 0xFF, count: 10 * 10 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: rgba as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 10,
            height: 10,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 40,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            encoded,
            "public.png" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        // Encoded PNG bytes are small (~100-200 bytes), but decoded buffer is 400 bytes > 200 budget
        let stored = FfiStoredImage(format: .png, width: 10, height: 10, pixels: encoded as Data)
        XCTAssertThrowsError(try MetalImageCache.decode(imageId: 400, from: stored)) { error in
            guard case .decodedMemoryExceedsBudget(let id, let bytes, let budget) = error as? MetalImageCacheError else {
                XCTFail("Expected decodedMemoryExceedsBudget, got \(error)")
                return
            }
            XCTAssertEqual(id, 400)
            XCTAssertEqual(bytes, 400)
            XCTAssertEqual(budget, 200)
        }
    }
}
