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
import QuartzCore

extension MetalTerminalRenderer {
    // MARK: - Rendering

    /// Plan and draw one frame into a layer's next drawable.
    ///
    /// Returns the frame's statistics whether or not anything was drawn: an
    /// invalid frame, or a layer with no drawable to hand out, is skipped and
    /// reported, not trapped on.
    @discardableResult
    public func render(
        frame: FfiRenderFrame,
        in layer: CAMetalLayer,
        overscanRows: Int = 0,
        verticalPixelOffset: Float = 0,
        horizontalPixelOffset: Float = 0
    ) -> TerminalMetalFrameStatistics {
        let scale = Float(layer.contentsScale)
        let viewport = TerminalMetalViewport(
            drawableSize: layer.drawableSize,
            backingScale: scale,
            verticalPixelOffset: verticalPixelOffset,
            horizontalPixelOffset: horizontalPixelOffset
        )
        var stats = plan(frame: frame, viewport: viewport, overscanRows: overscanRows)
        guard stats.isRenderable else { return finish(stats, .notSubmitted) }
        guard let drawable = nextDrawableProvider(layer) else { return finish(stats, .noDrawable) }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        let presentation = draw(
            viewport: viewport,
            descriptor: descriptor,
            drawable: drawable,
            capture: committedFrameCaptureForTesting.map { hook in
                { (pixels: [UInt8]) in hook(frame, pixels) }
            }
        )
        stats = finish(stats, presentation)
        return stats
    }

    /// Record how a frame ended and, when it never reached a render target,
    /// drop the planner's claim on it. `statistics` is the value a host reads
    /// after a redraw, so it carries the outcome too.
    func finish(
        _ stats: TerminalMetalFrameStatistics,
        _ presentation: TerminalMetalFramePresentation
    ) -> TerminalMetalFrameStatistics {
        var stats = stats
        stats.presentation = presentation
        if presentation.leavesStalePixels {
            planner.discardPlannedFrame()
        }
        statistics = stats
        return stats
    }

    /// Plan and draw one frame into an arbitrary render pass -- an offscreen
    /// texture, a shared drawable, a test.
    @discardableResult
    public func render(
        frame: FfiRenderFrame,
        viewport: TerminalMetalViewport,
        descriptor: MTLRenderPassDescriptor,
        drawable: MTLDrawable? = nil,
        waitUntilCompleted: Bool = false,
        overscanRows: Int = 0
    ) -> TerminalMetalFrameStatistics {
        let stats = plan(frame: frame, viewport: viewport, overscanRows: overscanRows)
        guard stats.isRenderable else { return finish(stats, .notSubmitted) }
        let presentation = draw(
            viewport: viewport,
            descriptor: descriptor,
            drawable: drawable,
            waitUntilCompleted: waitUntilCompleted
        )
        return finish(stats, presentation)
    }

    @discardableResult
    func draw(
        viewport: TerminalMetalViewport,
        descriptor: MTLRenderPassDescriptor,
        drawable: MTLDrawable?,
        waitUntilCompleted: Bool = false,
        capture: (([UInt8]) -> Void)? = nil
    ) -> TerminalMetalFramePresentation {
        inFlight.wait()
        slot = (slot + 1) % Self.framesInFlight

        uploadDirtyAtlasPages()
        resolveImageTextures()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return .noCommandBuffer
        }
        commandBuffer.label = "TerminalFrame"
        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }

        var terminalDescriptor = descriptor
        var shaderIntermediates: [MTLTexture] = []
        if !customShaders.isEmpty, let target = descriptor.colorAttachments[0].texture,
           let intermediates = customShaderIntermediates(for: target),
           let offscreen = descriptor.copy() as? MTLRenderPassDescriptor {
            offscreen.colorAttachments[0].texture = intermediates[0]
            terminalDescriptor = offscreen
            shaderIntermediates = intermediates
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: terminalDescriptor) else {
            commandBuffer.commit()
            return .noCommandEncoder
        }
        encoder.label = "TerminalPasses"
        encode(into: encoder, viewport: viewport)
        encoder.endEncoding()

        if let target = descriptor.colorAttachments[0].texture, !shaderIntermediates.isEmpty,
           !encodeCustomShaders(into: commandBuffer, intermediates: shaderIntermediates, target: target) {
            commandBuffer.commit()
            return .noCommandEncoder
        }

        let captureBuffer = capture == nil ? nil : encodeCapture(into: commandBuffer, from: descriptor)

        if let drawable {
            #if targetEnvironment(simulator)
            #else
            drawable.addPresentedHandler { [weak self] presented in
                self?.presentationClock.record(presentedAt: presented.presentedTime)
            }
            #endif
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
        if drawable != nil {
            presentationClock.recordSubmitted()
        }
        if waitUntilCompleted || captureBuffer != nil {
            commandBuffer.waitUntilCompleted()
        }
        if let capture, let captureBuffer {
            let raw = captureBuffer.contents().assumingMemoryBound(to: UInt8.self)
            capture([UInt8](UnsafeBufferPointer(start: raw, count: captureBuffer.length)))
        }
        return drawable == nil ? .committedOffscreen : .presented
    }

    /// Blit this pass's color target into shared memory. Returns nil -- and
    /// encodes nothing -- when the target cannot be read back, so a capture
    /// that is impossible degrades to no capture rather than to a wrong one.
    func encodeCapture(
        into commandBuffer: MTLCommandBuffer,
        from descriptor: MTLRenderPassDescriptor
    ) -> MTLBuffer? {
        guard let texture = descriptor.colorAttachments[0].texture else { return nil }
        let bytesPerRow = texture.width * 4
        let length = bytesPerRow * texture.height
        guard length > 0,
              let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: length)
        blit.endEncoding()
        return buffer
    }
}
