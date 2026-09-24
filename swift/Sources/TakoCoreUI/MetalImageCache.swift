import Foundation
import CoreGraphics
import ImageIO
import Metal

/// Deterministic per-pixel conversion result before uploading to Metal.
public struct MetalImageUpload: Equatable {
    /// Original image identifier from Kitty graphics (`imageId`).
    public let imageId: UInt32
    /// Width in pixels.
    public let width: Int
    /// Height in pixels.
    public let height: Int
    /// Pixel format requested by Kitty after conversion.
    public let format: FfiImageFormat
    /// `BGRA` packed bytes with premultiplied alpha.
    public let bgraPixels: Data
    /// Stable hash of the upload payload and metadata used to detect content change.
    public let contentIdentity: UInt64

    /// Expected bytes for a `BGRA8Unorm` upload (`width * height * 4`).
    public var bytesPerRow: Int { width * 4 }

    /// Expected total byte count for the upload payload.
    public var byteCount: Int { bgraPixels.count }
}

/// Entry describing one cached image version keyed by image id + content identity.
public struct MetalImageCacheMetadata: Hashable {
    /// Image id from Kitty graphics.
    public let imageId: UInt32
    /// Stable hash of the decoded bytes and metadata used to detect churn.
    public let contentIdentity: UInt64
    /// Width in pixels.
    public let width: Int
    /// Height in pixels.
    public let height: Int
    /// Original Kitty format, before conversion.
    public let format: FfiImageFormat
}

/// One cached record. `texture` is `nil` when no `MTLDevice` was supplied.
public struct MetalImageCacheEntry {
    public let metadata: MetalImageCacheMetadata
    public let texture: MTLTexture?

    public init(metadata: MetalImageCacheMetadata, texture: MTLTexture?) {
        self.metadata = metadata
        self.texture = texture
    }
}

/// Errors surfaced while decoding, hashing, or caching images.
public enum MetalImageCacheError: Error {
    case invalidDimensions(imageId: UInt32, width: UInt32, height: UInt32)
    case pngDimensionMismatch(
        imageId: UInt32,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case invalidPixelByteCount(imageId: UInt32, expected: Int, actual: Int)
    case overflow(imageId: UInt32)
    case pngDecodeFailed(imageId: UInt32)
    case textureCreationFailed(imageId: UInt32)
}

/// CPU-side converter and Metal texture cache for Kitty graphics images.
/// Input accepts `FfiStoredImage` in RGB, RGBA, or PNG form and always
/// converts to document-order `BGRA8` with premultiplied alpha for upload.
public final class MetalImageCache {
    private struct CachedEntry {
        let metadata: MetalImageCacheMetadata
        let texture: MTLTexture?
    }

    private let device: MTLDevice?
    /// Latest entry per image id.
    private var entriesByImageId: [UInt32: CachedEntry] = [:]
    /// Number of images currently cached.
    public var cachedCount: Int { entriesByImageId.count }

    public init(device: MTLDevice? = nil) {
        self.device = device
    }

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

    /// Cache an image by image id and content identity; reuses the same texture when
    /// the converted payload is unchanged.
    public func cache(imageId: UInt32, storedImage: FfiStoredImage) throws -> MetalImageCacheEntry {
        let upload = try Self.decode(imageId: imageId, from: storedImage)
        let metadata = MetalImageCacheMetadata(
            imageId: imageId,
            contentIdentity: upload.contentIdentity,
            width: upload.width,
            height: upload.height,
            format: upload.format
        )

        if let existing = entriesByImageId[imageId], existing.metadata == metadata {
            return MetalImageCacheEntry(metadata: existing.metadata, texture: existing.texture)
        }

        let texture = try makeTexture(from: upload)
        let entry = CachedEntry(metadata: metadata, texture: texture)
        entriesByImageId[imageId] = entry
        return MetalImageCacheEntry(metadata: metadata, texture: texture)
    }

    /// Remove cached entries whose image id is not referenced by placements.
    /// Returns removed image ids.
    @discardableResult
    public func purge(unusedBy placements: [FfiGraphicsPlacement]) -> [UInt32] {
        let alive: Set<UInt32> = Set(placements.map(\.imageId))
        return purge(unusedByImageIds: alive)
    }

    /// Remove cached entries not referenced by the provided image ids.
    /// Returns removed image ids.
    @discardableResult
    public func purge(unusedByImageIds imageIds: Set<UInt32>) -> [UInt32] {
        var removed = [UInt32]()
        for (imageId, _) in entriesByImageId where !imageIds.contains(imageId) {
            removed.append(imageId)
        }
        for imageId in removed {
            entriesByImageId.removeValue(forKey: imageId)
        }
        return removed
    }

    /// Read current metadata for an image id, if cached.
    public func metadata(for imageId: UInt32) -> MetalImageCacheMetadata? {
        return entriesByImageId[imageId]?.metadata
    }

    /// Snapshot metadata for all cached entries.
    public func allMetadata() -> [UInt32: MetalImageCacheMetadata] {
        return entriesByImageId.mapValues { $0.metadata }
    }

    private func makeTexture(from upload: MetalImageUpload) throws -> MTLTexture? {
        guard let device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: upload.width,
            height: upload.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalImageCacheError.textureCreationFailed(imageId: upload.imageId)
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, upload.width, upload.height),
            mipmapLevel: 0,
            withBytes: upload.bgraPixels.withUnsafeBytes { $0.baseAddress! },
            bytesPerRow: upload.bytesPerRow
        )
        return texture
    }

    private static func validatedDimensions(
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
        return (width, height)
    }

    private static func decodeRGB(imageId: UInt32, width: Int, height: Int, pixels: Data) throws -> Data {
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

    private static func decodeRGBA(imageId: UInt32, width: Int, height: Int, pixels: Data) throws -> Data {
        let expected = try expectedByteCount(
            imageId: imageId,
            width: width,
            height: height,
            components: 4
        )
        guard pixels.count == expected else {
            throw MetalImageCacheError.invalidPixelByteCount(imageId: imageId, expected: expected, actual: pixels.count)
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

    private static func decodePNG(imageId: UInt32, width: Int, height: Int, pixels: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(pixels as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = try checkedMul(width, 4, imageId: imageId)
        let outputCount = try checkedMul(bytesPerRow, height, imageId: imageId)
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

    /// Fold fixed-width values byte-by-byte in little-endian order so identities
    /// remain stable across CPU architectures.
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
