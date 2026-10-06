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
    func encode(into encoder: MTLRenderCommandEncoder, viewport: TerminalMetalViewport) {
        var uniform = viewport
        switch (planner.colorSpace, planner.colorEncoding) {
        case (.sRGB, .displayEncoded): uniform._pad = 0
        case (.sRGB, .linear): uniform._pad = 1
        case (.displayP3, .displayEncoded): uniform._pad = 2
        case (.displayP3, .linear): uniform._pad = 3
        }
        for pass in Self.passOrder where !planner.isEmpty(pass) {
            switch pass {
            case .background:
                guard let buffer = backgroundRing.upload(planner.backgroundInstances, slot: slot) else { continue }
                bind(encoder, pipeline: backgroundPipeline, uniform: &uniform, instances: buffer)
                drawQuads(encoder, instanceCount: planner.backgroundInstances.count)
            case .selection:
                guard let buffer = selectionRing.upload(planner.selectionInstances, slot: slot) else { continue }
                bind(encoder, pipeline: selectionPipeline, uniform: &uniform, instances: buffer)
                drawQuads(encoder, instanceCount: planner.selectionInstances.count)
            case .kittyImage:
                encodeImages(encoder, uniform: &uniform)
            case .grayscaleGlyph:
                encodeGlyphs(
                    encoder,
                    uniform: &uniform,
                    instances: planner.glyphInstances,
                    ranges: planner.glyphPageRanges,
                    ring: glyphRing,
                    pipeline: glyphPipeline
                )
            case .colorGlyph:
                encodeGlyphs(
                    encoder,
                    uniform: &uniform,
                    instances: planner.colorGlyphInstances,
                    ranges: planner.colorGlyphPageRanges,
                    ring: colorGlyphRing,
                    pipeline: colorGlyphPipeline
                )
            case .decoration:
                guard let buffer = decorationRing.upload(planner.decorationInstances, slot: slot) else { continue }
                bind(encoder, pipeline: decorationPipeline, uniform: &uniform, instances: buffer)
                drawQuads(encoder, instanceCount: planner.decorationInstances.count)
            case .cursor:
                guard let buffer = cursorRing.upload(planner.cursorInstances, slot: slot) else { continue }
                bind(encoder, pipeline: cursorPipeline, uniform: &uniform, instances: buffer)
                drawQuads(encoder, instanceCount: planner.cursorInstances.count)
            }
        }
    }

    func encodeImages(_ encoder: MTLRenderCommandEncoder, uniform: inout TerminalMetalViewport) {
        guard let buffer = imageRing.upload(planner.imageInstances, slot: slot) else { return }
        encoder.setRenderPipelineState(imagePipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<TerminalMetalViewport>.size, index: 0)
        encoder.setFragmentSamplerState(imageSampler, index: 0)
        let stride = MemoryLayout<TerminalMetalImageInstance>.stride
        for (index, instance) in planner.imageInstances.enumerated() {
            guard let texture = resolvedImageTextures[instance.imageId] else { continue }
            encoder.setVertexBuffer(buffer, offset: index * stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            drawQuads(encoder, instanceCount: 1)
        }
    }

    func encodeGlyphs(
        _ encoder: MTLRenderCommandEncoder,
        uniform: inout TerminalMetalViewport,
        instances: [TerminalMetalGlyphInstance],
        ranges: [(page: Int, range: Range<Int>)],
        ring: InstanceRing,
        pipeline: MTLRenderPipelineState
    ) {
        guard let buffer = ring.upload(instances, slot: slot) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<TerminalMetalViewport>.size, index: 0)
        encoder.setFragmentSamplerState(glyphSampler, index: 0)
        let stride = MemoryLayout<TerminalMetalGlyphInstance>.stride
        for group in ranges {
            guard group.page >= 0, group.page < atlasTextures.count,
                  let atlasTexture = atlasTextures[group.page], !group.range.isEmpty else { continue }
            encoder.setVertexBuffer(buffer, offset: group.range.lowerBound * stride, index: 1)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            drawQuads(encoder, instanceCount: group.range.count)
        }
    }

    func bind(
        _ encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        uniform: inout TerminalMetalViewport,
        instances: MTLBuffer
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<TerminalMetalViewport>.size, index: 0)
        encoder.setVertexBuffer(instances, offset: 0, index: 1)
    }

    func drawQuads(_ encoder: MTLRenderCommandEncoder, instanceCount: Int) {
        guard instanceCount > 0 else { return }
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: Self.quadIndices.count,
            indexType: .uint16,
            indexBuffer: quadIndexBuffer,
            indexBufferOffset: 0,
            instanceCount: instanceCount
        )
    }
}
