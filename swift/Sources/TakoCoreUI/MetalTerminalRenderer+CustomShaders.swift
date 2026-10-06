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
import Foundation
import Metal

extension MetalTerminalRenderer {
    // MARK: - Custom shaders

    /// Compile `custom-shader` sources, applied in the given order. As
    /// upstream does, one failure disables them all: the terminal is drawn
    /// as if none were configured and the reasons are returned.
    @discardableResult
    public func setCustomShaders(_ sources: [(name: String, glsl: String)]) -> [String] {
        var compiled: [TerminalCustomShader] = []
        var errors: [String] = []
        for source in sources {
            do {
                compiled.append(try TerminalCustomShader.compile(
                    glsl: source.glsl, name: source.name, device: device, pixelFormat: colorPixelFormat))
            } catch {
                errors.append(String(describing: error))
            }
        }
        applyCustomShaders(errors.isEmpty ? compiled : [], errors: errors)
        return errors
    }

    /// Read and compile `custom-shader` files. An unreadable file is a
    /// failure like a compile error.
    @discardableResult
    public func loadCustomShaders(paths: [String]) -> [String] {
        var sources: [(name: String, glsl: String)] = []
        var errors: [String] = []
        for path in paths {
            do {
                sources.append((URL(fileURLWithPath: path).lastPathComponent, try String(contentsOfFile: path, encoding: .utf8)))
            } catch {
                errors.append(String(describing: TerminalCustomShaderError.unreadable(
                    path: path, reason: (error as NSError).localizedDescription)))
            }
        }
        guard errors.isEmpty else {
            applyCustomShaders([], errors: errors)
            return errors
        }
        return setCustomShaders(sources)
    }

    func applyCustomShaders(_ shaders: [TerminalCustomShader], errors: [String]) {
        customShaders = shaders
        customShaderErrors = errors
        customShaderTargets = []
        customShaderUniforms = TerminalCustomShaderUniforms()
        customShaderStartTime = customShaderClock()
        customShaderLastFrameTime = nil
    }

    /// The offscreen textures the terminal passes and all but the last
    /// shader draw into, or nil when `target` cannot be shaded.
    func customShaderIntermediates(for target: MTLTexture) -> [MTLTexture]? {
        guard target.pixelFormat == colorPixelFormat else { return nil }
        let count = customShaders.count > 1 ? 2 : 1
        if customShaderTargets.count == count,
           customShaderTargets.allSatisfy({ $0.width == target.width && $0.height == target.height }) {
            return customShaderTargets
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat, width: target.width, height: target.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        var textures: [MTLTexture] = []
        for index in 0..<count {
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            texture.label = "CustomShaderTarget.\(index)"
            textures.append(texture)
        }
        customShaderTargets = textures
        return textures
    }

    /// Advance time, frame and cursor for the frame about to be shaded.
    func advanceCustomShaderUniforms(width: Int, height: Int) {
        var uniforms = customShaderUniforms
        let now = customShaderClock()
        let size = SIMD4<Float>(Float(width), Float(height), 1, 0)
        uniforms.resolution = size
        uniforms.channelResolution = size
        uniforms.time = Float(now - customShaderStartTime)
        uniforms.timeDelta = customShaderLastFrameTime.map { Float(now - $0) } ?? 0
        uniforms.frame = customShaderLastFrameTime == nil ? 0 : uniforms.frame &+ 1
        customShaderLastFrameTime = now

        let date = Date()
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = Float(parts.year ?? 0)
        let month = Float((parts.month ?? 1) - 1)
        let day = Float(parts.day ?? 1)
        let seconds = Float(date.timeIntervalSince(calendar.startOfDay(for: date)))
        uniforms.date = SIMD4<Float>(year, month, day, seconds)

        if let first = planner.cursorInstances.first {
            var minX = first.rect.x, minY = first.rect.y
            var maxX = first.rect.x + first.rect.z, maxY = first.rect.y + first.rect.w
            for instance in planner.cursorInstances.dropFirst() {
                minX = min(minX, instance.rect.x)
                minY = min(minY, instance.rect.y)
                maxX = max(maxX, instance.rect.x + instance.rect.z)
                maxY = max(maxY, instance.rect.y + instance.rect.w)
            }
            let x = minX + planner.viewport.horizontalPixelOffset
            let top = minY + planner.viewport.verticalPixelOffset
            let cursor = SIMD4<Float>(x, Float(height) - top, maxX - minX, maxY - minY)
            if cursor != uniforms.currentCursor || first.color != uniforms.currentCursorColor {
                uniforms.previousCursor = uniforms.currentCursor == .zero ? cursor : uniforms.currentCursor
                uniforms.previousCursorColor = uniforms.currentCursor == .zero ? first.color : uniforms.currentCursorColor
                uniforms.currentCursor = cursor
                uniforms.currentCursorColor = first.color
                uniforms.timeCursorChange = uniforms.time
            }
        }
        customShaderUniforms = uniforms
    }

    /// Run every custom shader as a full-screen pass: the terminal image in
    /// `intermediates[0]`, ping-ponging through `intermediates[1]`, the last
    /// pass writing `target`. False when an encoder could not be made.
    func encodeCustomShaders(
        into commandBuffer: MTLCommandBuffer,
        intermediates: [MTLTexture],
        target: MTLTexture
    ) -> Bool {
        advanceCustomShaderUniforms(width: target.width, height: target.height)
        var uniforms = customShaderUniforms
        var input = intermediates[0]
        for (index, shader) in customShaders.enumerated() {
            let output = index == customShaders.count - 1 ? target : intermediates[(index + 1) % intermediates.count]
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.label = "CustomShader.\(shader.name)"
            encoder.setRenderPipelineState(shader.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TerminalCustomShaderUniforms>.stride, index: 0)
            encoder.setFragmentTexture(input, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            input = output
        }
        return true
    }
}
