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

/// CPU-side converter and Metal texture cache for Kitty graphics images.
/// Input accepts `FfiStoredImage` in RGB, RGBA, or PNG form and always
/// converts to document-order `BGRA8` with premultiplied alpha for upload.
public final class MetalImageCache {
    /// Default maximum memory budget allocated for a single decoded image buffer (64 MiB).
    public static let defaultMaxDecodedImageBytes: Int = 64 * 1024 * 1024
    /// Configurable ceiling for decoded pixel buffers.
    public static var maxDecodedImageBytes: Int = defaultMaxDecodedImageBytes

    private struct CachedEntry {
        let metadata: MetalImageCacheMetadata
        let texture: MTLTexture?
        let byteSize: Int
        var lastAccessedGeneration: UInt64
    }

    private let device: MTLDevice?
    /// Latest entry per image id.
    private var entriesByImageId: [UInt32: CachedEntry] = [:]
    private var totalCachedBytes: Int = 0
    private var accessCounter: UInt64 = 0

    /// Total bytes currently resident in the decoded texture cache.
    public var currentDecodedBytes: Int { totalCachedBytes }
    /// Number of images currently cached.
    public var cachedCount: Int { entriesByImageId.count }

    public init(device: MTLDevice? = nil) {
        self.device = device
    }

    /// Cache an image by image id and content identity; reuses the same texture when
    /// the converted payload is unchanged. Evicts older textures in LRU order if
    /// aggregate decoded memory exceeds the configured budget.
    public func cache(imageId: UInt32, storedImage: FfiStoredImage) throws -> MetalImageCacheEntry {
        let upload = try Self.decode(imageId: imageId, from: storedImage)
        let metadata = MetalImageCacheMetadata(
            imageId: imageId,
            contentIdentity: upload.contentIdentity,
            width: upload.width,
            height: upload.height,
            format: upload.format
        )

        accessCounter &+= 1

        if var existing = entriesByImageId[imageId], existing.metadata == metadata {
            existing.lastAccessedGeneration = accessCounter
            entriesByImageId[imageId] = existing
            return MetalImageCacheEntry(metadata: existing.metadata, texture: existing.texture)
        }

        let requiredBytes = upload.byteCount

        // If replacing an existing entry for this imageId, release its bytes first.
        if let existing = entriesByImageId.removeValue(forKey: imageId) {
            totalCachedBytes -= existing.byteSize
        }

        // Evict LRU entries until the new image fits within the aggregate budget.
        while totalCachedBytes + requiredBytes > Self.maxDecodedImageBytes, !entriesByImageId.isEmpty {
            guard let oldest = entriesByImageId.min(by: { $0.value.lastAccessedGeneration < $1.value.lastAccessedGeneration }) else {
                break
            }
            entriesByImageId.removeValue(forKey: oldest.key)
            totalCachedBytes -= oldest.value.byteSize
        }

        guard totalCachedBytes + requiredBytes <= Self.maxDecodedImageBytes else {
            throw MetalImageCacheError.decodedMemoryExceedsBudget(
                imageId: imageId,
                bytes: totalCachedBytes + requiredBytes,
                maxBudget: Self.maxDecodedImageBytes
            )
        }

        let texture = try makeTexture(from: upload)
        let entry = CachedEntry(
            metadata: metadata,
            texture: texture,
            byteSize: requiredBytes,
            lastAccessedGeneration: accessCounter
        )
        entriesByImageId[imageId] = entry
        totalCachedBytes += requiredBytes
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
        for (imageId, entry) in entriesByImageId where !imageIds.contains(imageId) {
            removed.append(imageId)
            totalCachedBytes -= entry.byteSize
        }
        for imageId in removed {
            entriesByImageId.removeValue(forKey: imageId)
        }
        return removed
    }

    /// Read current metadata for an image id, if cached.
    public func metadata(for imageId: UInt32) -> MetalImageCacheMetadata? {
        if var entry = entriesByImageId[imageId] {
            accessCounter &+= 1
            entry.lastAccessedGeneration = accessCounter
            entriesByImageId[imageId] = entry
            return entry.metadata
        }
        return nil
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
}
