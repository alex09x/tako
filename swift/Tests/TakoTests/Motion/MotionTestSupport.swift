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
import QuartzCore
import SwiftUI
import Testing
@testable import Tako

/// A SwiftUI view drawn the way its window draws it -- an NSHostingView into
/// `cacheDisplay` -- with its pixels in sRGB. ImageRenderer draws some things
/// differently from a window (macOS 15 drew offset gradients unshifted on
/// screen, right in ImageRenderer), so motion is checked on this.
@MainActor
struct WindowSnapshot {
    let size: CGSize
    let pixelsWide: Int
    let pixelsHigh: Int
    private let bytes: [UInt8]

    init<V: View>(_ view: V, size: CGSize) {
        self.size = size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        // Redrawn into a known layout: sRGB, 8-bit RGBA, not premultiplied by surprise.
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixelsWide = w
        pixelsHigh = h
        bytes = raw
    }

    /// Pixels per point.
    var scale: CGFloat { CGFloat(pixelsWide) / size.width }

    /// sRGB components, 0...1, of the pixel at `x`, `y` (pixels, top-left origin).
    func rgb(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let i = (y * pixelsWide + x) * 4
        return (CGFloat(bytes[i]) / 255, CGFloat(bytes[i + 1]) / 255, CGFloat(bytes[i + 2]) / 255)
    }

    /// The point at the centre of pixel `x`, `y`, y down.
    func point(_ x: Int, _ y: Int) -> CGPoint {
        CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
    }

    /// `weight` of every pixel, summed down each column, in points from the left.
    func columns(_ weight: (CGFloat, CGFloat, CGFloat) -> CGFloat) -> [(x: CGFloat, sum: CGFloat)] {
        (0..<pixelsWide).map { x in
            var sum: CGFloat = 0
            for y in 0..<pixelsHigh {
                let c = rgb(x, y)
                sum += weight(c.r, c.g, c.b)
            }
            return (point(x, 0).x, sum / CGFloat(pixelsHigh))
        }
    }

    /// The pixels whose `weight` is over `threshold`, as points with their weight.
    func points(over threshold: CGFloat, _ weight: (CGFloat, CGFloat, CGFloat) -> CGFloat) -> [(p: CGPoint, w: CGFloat)] {
        var out: [(CGPoint, CGFloat)] = []
        for y in 0..<pixelsHigh {
            for x in 0..<pixelsWide {
                let c = rgb(x, y)
                let w = weight(c.r, c.g, c.b)
                if w > threshold { out.append((point(x, y), w)) }
            }
        }
        return out
    }

    /// Green above red and blue: the done green over a dark surface.
    static func greenExcess(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat { max(0, g - max(r, b)) }
    /// Red above green and blue: Claw, Ember, Rust and the failed red over a dark surface.
    static func redExcess(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat { max(0, r - max(g, b)) }
}

/// Reads a Core Animation animation at a chosen time without a screen: a copy
/// on a stopped probe layer (speed 0) moved to `t` with `timeOffset`. The
/// probe lives in a window's layer tree, as `presentation()` is nil for a
/// layer that was never committed into one.
@MainActor
final class AnimationClock {
    private let window: NSWindow
    private let host: CALayer

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: window.contentLayoutRect)
        view.wantsLayer = true
        window.contentView = view
        host = view.layer!
    }

    /// The presentation of `probe` running `animation` from time 0, at each
    /// of `times`. A shape layer's own properties need a shape layer probe.
    func sample(_ animation: CAAnimation, on probe: CALayer = CALayer(), at times: [TimeInterval]) -> [CALayer] {
        probe.speed = 0
        host.addSublayer(probe)
        defer { probe.removeFromSuperlayer() }
        let running = animation.copy() as! CAAnimation
        running.beginTime = 1e-6
        running.fillMode = .both
        probe.add(running, forKey: "sampled")
        CATransaction.flush()
        let frames = times.compactMap { t -> CALayer? in
            probe.timeOffset = t
            CATransaction.flush()
            return probe.presentation()
        }
        // A missing frame would shorten every zip over these without a word.
        if frames.count != times.count {
            Issue.record("\(times.count - frames.count) of \(times.count) times had no presentation")
        }
        return frames
    }
}

extension CALayer {
    /// The first animation under `key` on this layer or any layer below it.
    func animationInTree(forKey key: String) -> (layer: CALayer, animation: CAAnimation)? {
        if let found = animation(forKey: key) { return (self, found) }
        for sub in sublayers ?? [] {
            if let found = sub.animationInTree(forKey: key) { return found }
        }
        return nil
    }

    /// The first layer of type `L` in this tree.
    func firstInTree<L: CALayer>(_ type: L.Type) -> L? {
        if let me = self as? L { return me }
        for sub in sublayers ?? [] {
            if let found = sub.firstInTree(type) { return found }
        }
        return nil
    }
}
