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

extension MetalTerminalRenderer {
    // MARK: - Atlas and image textures

    /// Upload only changed generations, copy-on-writing each texture so a
    /// command buffer sampling the previous generation can finish safely.
    func uploadDirtyAtlasPages() {
        let pages = planner.atlas.pages
        if atlasTextures.count > pages.count {
            atlasTextures.removeLast(atlasTextures.count - pages.count)
            atlasTextureGenerations.removeLast(atlasTextureGenerations.count - pages.count)
        }
        while atlasTextures.count < pages.count {
            atlasTextures.append(nil)
            atlasTextureGenerations.append(0)
        }

        for index in pages.indices where atlasTextures[index] == nil || atlasTextureGenerations[index] != pages[index].generation {
            guard let data = planner.atlas.textureData(pageIndex: index) else { continue }
            let page = pages[index]
            guard data.count >= page.bytesPerRow * page.height else { continue }
            guard let texture = makeAtlasTexture(page: page) else { continue }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, page.width, page.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: page.bytesPerRow
                )
            }
            atlasTextures[index] = texture
            atlasTextureGenerations[index] = page.generation
            atlasUploadCount += 1
        }
        planner.clearDirtyAtlasPages()
    }

    func makeAtlasTexture(page: GlyphAtlasPage) -> MTLTexture? {
        guard page.width > 0, page.height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: page.pixelFormat == .grayscale8 ? .r8Unorm : .bgra8Unorm,
            width: page.width,
            height: page.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = page.pixelFormat == .grayscale8 ? "TerminalGlyphAtlas.Gray" : "TerminalGlyphAtlas.Color"
        return texture
    }

    /// Decode and upload the images this frame's placements need, once each.
    /// A malformed image is dropped -- `MetalImageCache` throws rather than
    /// trapping, and the placement simply does not draw.
    func resolveImageTextures() {
        guard !planner.imageInstances.isEmpty else {
            if !resolvedImageTextures.isEmpty {
                resolvedImageTextures.removeAll(keepingCapacity: true)
                resolvedImageMetadata.removeAll(keepingCapacity: true)
            }
            imageCache.purge(unusedByImageIds: [])
            return
        }

        var live = Set<UInt32>()
        for instance in planner.imageInstances {
            let imageId = instance.imageId
            live.insert(imageId)
            let metadata = frameImageMetadata[imageId]
            if resolvedImageTextures[imageId] != nil {
                guard let metadata else { continue }
                guard resolvedImageMetadata[imageId] != metadata else { continue }
            }
            guard let stored = imageProvider(imageId) else { continue }
            guard let entry = try? imageCache.cache(imageId: imageId, storedImage: stored),
                  let texture = entry.texture else { continue }
            resolvedImageTextures[imageId] = texture
            resolvedImageMetadata[imageId] = metadata ?? FfiGraphicsImageMetadata(
                format: stored.format,
                width: stored.width,
                height: stored.height,
                generation: 0
            )
        }

        for imageId in resolvedImageTextures.keys.filter({ !live.contains($0) }) {
            resolvedImageTextures.removeValue(forKey: imageId)
            resolvedImageMetadata.removeValue(forKey: imageId)
        }
        imageCache.purge(unusedByImageIds: live)
    }

    // MARK: - Pipeline construction

    static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        pass: String,
        vertex: String,
        fragment: String,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertex) else {
            throw MetalTerminalRendererError.missingShaderFunction(vertex)
        }
        guard let fragmentFunction = library.makeFunction(name: fragment) else {
            throw MetalTerminalRendererError.missingShaderFunction(fragment)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "TerminalPass.\(pass)"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = pixelFormat
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalTerminalRendererError.pipelineCreationFailed(
                pass: pass,
                message: (error as NSError).localizedDescription
            )
        }
    }

    static func makeSampler(device: MTLDevice, filter: MTLSamplerMinMagFilter) throws -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw MetalTerminalRendererError.samplerCreationFailed
        }
        return sampler
    }

    /// One instance buffer per frame in flight, grown on demand and reused
    /// forever after.
    final class InstanceRing {
        let device: MTLDevice
        let label: String
        var slots: [MTLBuffer?]
        private(set) var allocations = 0

        init(device: MTLDevice, label: String, slotCount: Int = MetalTerminalRenderer.framesInFlight) {
            self.device = device
            self.label = label
            self.slots = Array(repeating: nil, count: max(slotCount, 1))
        }

        func upload<Instance>(_ instances: [Instance], slot: Int) -> MTLBuffer? {
            guard !instances.isEmpty else { return nil }
            let index = slot % slots.count
            let required = MemoryLayout<Instance>.stride * instances.count
            if let length = TerminalMetalBufferSizing.growth(
                existingLength: slots[index]?.length ?? 0,
                requiredLength: required
            ) {
                guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                    return nil
                }
                buffer.label = "\(label).\(index)"
                slots[index] = buffer
                allocations += 1
            }
            guard let buffer = slots[index] else { return nil }
            instances.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count <= buffer.length else { return }
                buffer.contents().copyMemory(from: base, byteCount: raw.count)
            }
            return buffer
        }
    }
}
