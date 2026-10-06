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
public enum MetalImageCacheError: Error, Equatable {
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
    case decodedMemoryExceedsBudget(imageId: UInt32, bytes: Int, maxBudget: Int)
}
