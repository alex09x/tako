/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Metal
import QuartzCore
import Testing
@testable import Tako

/// A layer tree as the render server draws it at a moment of its animations:
/// CARenderer into a Metal texture, so masks, conic gradients and shadows are
/// drawn -- `render(in:)` leaves masks out, and the comet and the spinner are
/// masks -- and no screen or Screen Recording is needed.
@MainActor
struct LayerFrame: CustomStringConvertible {
    let pixelsWide: Int
    let pixelsHigh: Int
    let scale: CGFloat
    private let bytes: [UInt8]   // RGBA, sRGB, premultiplied; row 0 is the layer's y 0, its bottom

    fileprivate init(pixelsWide: Int, pixelsHigh: Int, scale: CGFloat, bytes: [UInt8]) {
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.scale = scale
        self.bytes = bytes
    }

    nonisolated var description: String { "LayerFrame(\(pixelsWide)x\(pixelsHigh))" }

    /// sRGB components, 0...1, at pixel `x`, `y` (bottom-left origin, as the layer's).
    func rgba(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let i = (y * pixelsWide + x) * 4
        return (CGFloat(bytes[i]) / 255, CGFloat(bytes[i + 1]) / 255, CGFloat(bytes[i + 2]) / 255, CGFloat(bytes[i + 3]) / 255)
    }

    /// The colour at a point of the layer's own space (y up, as Core Animation has it).
    func color(atPoint p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let x = min(pixelsWide - 1, max(0, Int(p.x * scale)))
        let y = min(pixelsHigh - 1, max(0, Int(p.y * scale)))
        return rgba(x, y)
    }

    /// Pixels in `rect` (layer points, y up) whose `weight` passes `threshold`,
    /// as points in the same space with their weight.
    func points(in rect: CGRect? = nil, over threshold: CGFloat,
                _ weight: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGFloat) -> [(p: CGPoint, w: CGFloat)] {
        var out: [(CGPoint, CGFloat)] = []
        for y in 0..<pixelsHigh {
            for x in 0..<pixelsWide {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                if let rect, !rect.contains(p) { continue }
                let c = rgba(x, y)
                let w = weight(c.r, c.g, c.b, c.a)
                if w > threshold { out.append((p, w)) }
            }
        }
        return out
    }

    /// The weighted centre of the pixels `points` found, or nil when none were.
    func centroid(in rect: CGRect? = nil, over threshold: CGFloat,
                  _ weight: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGFloat) -> CGPoint? {
        let hits = points(in: rect, over: threshold, weight)
        let total = hits.reduce(0) { $0 + $1.w }
        guard total > 0 else { return nil }
        return CGPoint(x: hits.reduce(0) { $0 + $1.p.x * $1.w } / total, y: hits.reduce(0) { $0 + $1.p.y * $1.w } / total)
    }

    /// The summed weight of the pixels in `rect`.
    func mass(in rect: CGRect? = nil, _ weight: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGFloat) -> CGFloat {
        points(in: rect, over: 0, weight).reduce(0) { $0 + $1.w }
    }

    /// Red above green and blue: Ember, Claw, Rust and the failed red on a dark surface.
    static func redExcess(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGFloat { max(0, r - max(g, b)) }
    /// Green above red and blue: the done green.
    static func greenExcess(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGFloat { max(0, g - max(r, b)) }
    /// Any colour at all over the black the frames are drawn on.
    static func light(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGFloat { max(r, g, b) }
}

/// Renders layer trees with CARenderer at chosen moments of their animations.
@MainActor
final class LayerFrames {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// The media time every animation of a tree is moved to start at.
    static let start: CFTimeInterval = 1_000

    init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
    }

    /// Every animation under `root` restarted at `start`, so that `at: t`
    /// means `t` seconds into each of them -- as a state change that just
    /// happened would run.
    static func restartAnimations(in root: CALayer) {
        func walk(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key)?.copy() as? CAAnimation else { continue }
                animation.beginTime = start
                // By the real clock a one-off at `start` ended long ago, and
                // a commit would take it off before it was drawn.
                animation.isRemovedOnCompletion = false
                layer.removeAnimation(forKey: key)
                layer.add(animation, forKey: key)
            }
            layer.sublayers?.forEach(walk)
            if let mask = layer.mask { walk(mask) }
        }
        walk(root)
    }

    /// `layer` drawn over black at `t` seconds after `start`, `size` points
    /// at `scale` pixels a point, with `padding` points round it for what
    /// it draws outside itself (a glow, a halo). The layer is moved under a
    /// root of the renderer's own and stays there; the frame's points are
    /// the layer's own moved by `padding`.
    func render(_ layer: CALayer, size: CGSize, padding: CGFloat = 0, scale: CGFloat = 2, at t: CFTimeInterval) -> LayerFrame {
        let full = CGSize(width: size.width + 2 * padding, height: size.height + 2 * padding)
        let w = Int((full.width * scale).rounded()), h = Int((full.height * scale).rounded())
        let root: CALayer
        let shift: CALayer
        if let existing = layer.superlayer, existing.name == "LayerFrames.shift", let top = existing.superlayer {
            root = top
            shift = existing
        } else {
            root = CALayer()
            root.name = "LayerFrames.root"
            shift = CALayer()
            shift.name = "LayerFrames.shift"
            root.addSublayer(shift)
            layer.removeFromSuperlayer()
            shift.addSublayer(layer)
        }
        shift.anchorPoint = .zero
        shift.bounds = CGRect(origin: .zero, size: size)
        shift.position = CGPoint(x: padding, y: padding)
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        root.position = .zero
        root.backgroundColor = NSColor.black.cgColor
        root.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
        root.isGeometryFlipped = false

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        let texture = device.makeTexture(descriptor: descriptor)!
        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            kCARendererMetalCommandQueue: queue,
        ])
        renderer.layer = root
        renderer.bounds = root.bounds
        // The renderer draws what was committed.
        CATransaction.flush()
        renderer.beginFrame(atTime: Self.start + t, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        // The renderer's work went into `queue`: one more buffer behind it ends after it.
        let fence = queue.makeCommandBuffer()!
        if texture.storageMode == .managed {
            let blit = fence.makeBlitCommandEncoder()!
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        fence.commit()
        fence.waitUntilCompleted()
        renderer.layer = nil

        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bgra, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = bgra[i + 2]
            rgba[i + 2] = bgra[i]
        }
        return LayerFrame(pixelsWide: w, pixelsHigh: h, scale: scale, bytes: rgba)
    }
}
