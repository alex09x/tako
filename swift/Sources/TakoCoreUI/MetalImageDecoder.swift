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

extension MetalImageCache {
    /// Convert one frame of image data into deterministic, premultiplied BGRA8 payload.
    public static func decode(imageId: UInt32, from image: FfiStoredImage) throws -> MetalImageUpload {
        let (width, height) = try validatedDimensions(
            width: image.width,
            height: image.height,
            imageId: imageId
        )

        let bgraPixels: Data = switch image.format {
        case .rgb:
            try decodeRGB(imageId: imageId, width: width, height: height, pixels: image.pixels)
        case .rgba:
            try decodeRGBA(imageId: imageId, width: width, height: height, pixels: image.pixels)
        case .png:
            try decodePNG(imageId: imageId, width: width, height: height, pixels: image.pixels)
        }

        let contentIdentity = contentIdentity(
            imageId: imageId,
            format: image.format,
            width: width,
            height: height,
            bgraPixels: bgraPixels
        )

        return MetalImageUpload(
            imageId: imageId,
            width: width,
            height: height,
            format: image.format,
            bgraPixels: bgraPixels,
            contentIdentity: contentIdentity
        )
    }

    static func validatedDimensions(
        width rawWidth: UInt32,
        height rawHeight: UInt32,
        imageId: UInt32
    ) throws -> (Int, Int) {
        guard rawWidth > 0, rawHeight > 0,
              let width = Int(exactly: rawWidth),
              let height = Int(exactly: rawHeight) else {
            throw MetalImageCacheError.invalidDimensions(
                imageId: imageId,
                width: rawWidth,
                height: rawHeight
            )
        }
        let bytesPerRow = try checkedMul(width, 4, imageId: imageId)
        let totalBytes = try checkedMul(bytesPerRow, height, imageId: imageId)
        guard totalBytes <= maxDecodedImageBytes else {
            throw MetalImageCacheError.decodedMemoryExceedsBudget(
                imageId: imageId,
                bytes: totalBytes,
                maxBudget: maxDecodedImageBytes
            )
        }
        return (width, height)
    }

    static func decodeRGB(imageId: UInt32, width: Int, height: Int, pixels: Data) throws -> Data {
        let expected = try expectedByteCount(
            imageId: imageId,
            width: width,
            height: height,
            components: 3
        )
        guard pixels.count == expected else {
            throw MetalImageCacheError.invalidPixelByteCount(imageId: imageId, expected: expected, actual: pixels.count)
        }

        let outputCount = try expectedByteCount(
            imageId: imageId,
            width: width,
            height: height,
            components: 4
        )
        guard outputCount <= maxDecodedImageBytes else {
            throw MetalImageCacheError.decodedMemoryExceedsBudget(
                imageId: imageId,
                bytes: outputCount,
                maxBudget: maxDecodedImageBytes
            )
        }
        var output = Data(count: outputCount)
        pixels.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                let source = sourceBytes.bindMemory(to: UInt8.self)
                let destination = destinationBytes.bindMemory(to: UInt8.self)
                for pixel in 0..<(width * height) {
                    let sourceOffset = pixel * 3
                    let destinationOffset = pixel * 4
                    destination[destinationOffset] = source[sourceOffset + 2]
                    destination[destinationOffset + 1] = source[sourceOffset + 1]
                    destination[destinationOffset + 2] = source[sourceOffset]
                    destination[destinationOffset + 3] = 0xFF
                }
            }
        }
        return output
    }

    static func decodeRGBA(imageId: UInt32, width: Int, height: Int, pixels: Data) throws -> Data {
        let expected = try expectedByteCount(
            imageId: imageId,
            width: width,
            height: height,
            components: 4
        )
        guard pixels.count == expected else {
            throw MetalImageCacheError.invalidPixelByteCount(imageId: imageId, expected: expected, actual: pixels.count)
        }
        guard expected <= maxDecodedImageBytes else {
            throw MetalImageCacheError.decodedMemoryExceedsBudget(
                imageId: imageId,
                bytes: expected,
                maxBudget: maxDecodedImageBytes
            )
        }

        var output = Data(count: expected)
        pixels.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                let source = sourceBytes.bindMemory(to: UInt8.self)
                let destination = destinationBytes.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: source.count, by: 4) {
                    let red = Int(source[offset])
                    let green = Int(source[offset + 1])
                    let blue = Int(source[offset + 2])
                    let alpha = Int(source[offset + 3])
                    destination[offset] = UInt8((blue * alpha + 127) / 255)
                    destination[offset + 1] = UInt8((green * alpha + 127) / 255)
                    destination[offset + 2] = UInt8((red * alpha + 127) / 255)
                    destination[offset + 3] = UInt8(alpha)
                }
            }
        }
        return output
    }

    static func decodePNG(imageId: UInt32, width: Int, height: Int, pixels: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(pixels as CFData, nil) else {
            throw MetalImageCacheError.pngDecodeFailed(imageId: imageId)
        }

        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
           let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int {
            guard pixelWidth == width, pixelHeight == height else {
                throw MetalImageCacheError.pngDimensionMismatch(
                    imageId: imageId,
                    expectedWidth: width,
                    expectedHeight: height,
                    actualWidth: pixelWidth,
                    actualHeight: pixelHeight
                )
            }
            let bytesPerRow = try checkedMul(pixelWidth, 4, imageId: imageId)
            let totalBytes = try checkedMul(bytesPerRow, pixelHeight, imageId: imageId)
            guard totalBytes <= maxDecodedImageBytes else {
                throw MetalImageCacheError.decodedMemoryExceedsBudget(
                    imageId: imageId,
                    bytes: totalBytes,
                    maxBudget: maxDecodedImageBytes
                )
            }
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MetalImageCacheError.pngDecodeFailed(imageId: imageId)
        }
        guard cgImage.width == width, cgImage.height == height else {
            throw MetalImageCacheError.pngDimensionMismatch(
                imageId: imageId,
                expectedWidth: width,
                expectedHeight: height,
                actualWidth: cgImage.width,
                actualHeight: cgImage.height
            )
        }

        let bytesPerRow = try checkedMul(width, 4, imageId: imageId)
        let outputCount = try checkedMul(bytesPerRow, height, imageId: imageId)
        guard outputCount <= maxDecodedImageBytes else {
            throw MetalImageCacheError.decodedMemoryExceedsBudget(
                imageId: imageId,
                bytes: outputCount,
                maxBudget: maxDecodedImageBytes
            )
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var output = Data(count: outputCount)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        let ok: Bool = output.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: info.rawValue
            ) else {
                return false
            }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.draw(cgImage, in: rect)
            return true
        }
        guard ok else {
            throw MetalImageCacheError.pngDecodeFailed(imageId: imageId)
        }
        return output
    }

    private static func expectedByteCount(
        imageId: UInt32,
        width: Int,
        height: Int,
        components: Int
    ) throws -> Int {
        let pixelCount = try checkedMul(width, height, imageId: imageId)
        return try checkedMul(pixelCount, components, imageId: imageId)
    }

    private static func checkedMul(_ lhs: Int, _ rhs: Int, imageId: UInt32) throws -> Int {
        let product = lhs.multipliedReportingOverflow(by: rhs)
        if product.overflow { throw MetalImageCacheError.overflow(imageId: imageId) }
        return product.partialValue
    }

    private static func contentIdentity(
        imageId: UInt32,
        format: FfiImageFormat,
        width: Int,
        height: Int,
        bgraPixels: Data
    ) -> UInt64 {
        let formatValue: UInt8 = switch format {
        case .rgb: 1
        case .rgba: 2
        case .png: 3
        }

        var hash: UInt64 = 14_695_981_039_346_656_037 // FNV-1a 64-bit offset basis
        hash = fold(hash: hash, UInt64(imageId))
        hash = fold(hash: hash, formatValue)
        hash = fold(hash: hash, UInt64(width))
        hash = fold(hash: hash, UInt64(height))
        hash = fold(hash: hash, bgraPixels)
        return hash
    }

    private static func fold(hash: UInt64, _ value: UInt8) -> UInt64 {
        var h = hash ^ UInt64(value)
        h = h &* 1_099_511_628_211
        return h
    }

    private static func fold(hash: UInt64, _ value: UInt64) -> UInt64 {
        var h = hash
        for shift in stride(from: 0, to: UInt64.bitWidth, by: 8) {
            h = fold(hash: h, UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
        return h
    }

    private static func fold(hash: UInt64, _ data: Data) -> UInt64 {
        var h = hash
        data.forEach { byte in
            h = fold(hash: h, byte)
        }
        return h
    }
}
