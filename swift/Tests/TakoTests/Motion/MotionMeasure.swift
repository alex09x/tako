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
@testable import Tako

/// A drawn frame read in points, y up, whichever engine drew it: Core
/// Animation through `LayerFrames`, SwiftUI through `WindowSnapshot`.
@MainActor
protocol MotionFrame {
    var widthInPoints: CGFloat { get }
    var heightInPoints: CGFloat { get }
    var pixelScale: CGFloat { get }
    /// sRGB 0...1 at the pixel whose centre is nearest `p` (points, y up).
    func sample(_ p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat)
}

extension LayerFrame: MotionFrame {
    var widthInPoints: CGFloat { CGFloat(pixelsWide) / scale }
    var heightInPoints: CGFloat { CGFloat(pixelsHigh) / scale }
    var pixelScale: CGFloat { scale }
    func sample(_ p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = color(atPoint: p)
        return (c.r, c.g, c.b)
    }
}

extension WindowSnapshot: MotionFrame {
    var widthInPoints: CGFloat { size.width }
    var heightInPoints: CGFloat { size.height }
    var pixelScale: CGFloat { scale }
    func sample(_ p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let x = min(pixelsWide - 1, max(0, Int(p.x * scale)))
        let y = min(pixelsHigh - 1, max(0, pixelsHigh - 1 - Int(p.y * scale)))
        return rgb(x, y)
    }
}

/// How much of a colour a pixel holds, over the dark surfaces the frames are drawn on.
typealias PixelWeight = (CGFloat, CGFloat, CGFloat) -> CGFloat

enum Weights {
    /// Red above green and blue: Ember, Claw, Rust, the failed red.
    static let warm: PixelWeight = { r, g, b in max(0, r - max(g, b)) }
    /// Green above red and blue: the done green.
    static let green: PixelWeight = { r, g, b in max(0, g - max(r, b)) }
    /// Any light at all.
    static let light: PixelWeight = { r, g, b in max(r, g, b) }
    /// Warm light above a card's own warm fill (#241C16).
    static let warmOverCard: PixelWeight = { r, g, b in max(0, r - max(g, b) - 0.06) }
    /// Close to `hex`, 1 at the colour and 0 a quarter of the way off.
    static func near(_ hex: Int) -> PixelWeight {
        let c = NSColor.spec(hex)
        return { r, g, b in
            let d = abs(r - c.redComponent) + abs(g - c.greenComponent) + abs(b - c.blueComponent)
            return max(0, 1 - d / 0.25)
        }
    }
}

@MainActor
extension MotionFrame {
    /// Every pixel centre in `rect` (points, y up; the whole frame when nil).
    func pixelCentres(in rect: CGRect? = nil) -> [CGPoint] {
        let area = rect ?? CGRect(x: 0, y: 0, width: widthInPoints, height: heightInPoints)
        let step = 1 / pixelScale
        var out: [CGPoint] = []
        var y = (area.minY * pixelScale).rounded(.down) / pixelScale + step / 2
        while y < area.maxY {
            var x = (area.minX * pixelScale).rounded(.down) / pixelScale + step / 2
            while x < area.maxX {
                if x >= 0, y >= 0, x < widthInPoints, y < heightInPoints { out.append(CGPoint(x: x, y: y)) }
                x += step
            }
            y += step
        }
        return out
    }

    func weighed(in rect: CGRect? = nil, where keep: (CGPoint) -> Bool = { _ in true },
                 _ weight: PixelWeight) -> [(p: CGPoint, w: CGFloat)] {
        pixelCentres(in: rect).compactMap { p in
            guard keep(p) else { return nil }
            let c = sample(p)
            let w = weight(c.r, c.g, c.b)
            return w > 0.02 ? (p, w) : nil
        }
    }

    /// The summed weight in `rect`, per square point.
    func mass(in rect: CGRect? = nil, where keep: (CGPoint) -> Bool = { _ in true }, _ weight: PixelWeight) -> CGFloat {
        weighed(in: rect, where: keep, weight).reduce(0) { $0 + $1.w } / (pixelScale * pixelScale)
    }

    func centroid(in rect: CGRect? = nil, where keep: (CGPoint) -> Bool = { _ in true }, _ weight: PixelWeight) -> CGPoint? {
        let hits = weighed(in: rect, where: keep, weight)
        let total = hits.reduce(0) { $0 + $1.w }
        guard total > 0 else { return nil }
        return CGPoint(x: hits.reduce(0) { $0 + $1.p.x * $1.w } / total, y: hits.reduce(0) { $0 + $1.p.y * $1.w } / total)
    }

    /// The direction of the weight around `centre`, in degrees, counter-
    /// clockwise from +x (y up): a circular mean, so a band across 0° is
    /// not averaged to 180°.
    func angle(around centre: CGPoint, in rect: CGRect? = nil, where keep: (CGPoint) -> Bool = { _ in true },
               _ weight: PixelWeight) -> Double? {
        let hits = weighed(in: rect, where: keep, weight)
        var sx = 0.0, sy = 0.0
        for h in hits {
            let a = atan2(Double(h.p.y - centre.y), Double(h.p.x - centre.x))
            sx += cos(a) * Double(h.w)
            sy += sin(a) * Double(h.w)
        }
        guard hypot(sx, sy) > 1e-6 else { return nil }
        return atan2(sy, sx) * 180 / .pi
    }

    /// How far out the weight lies from `centre`: the weighted mean radius.
    func radius(around centre: CGPoint, in rect: CGRect? = nil, _ weight: PixelWeight) -> CGFloat? {
        let hits = weighed(in: rect, weight)
        let total = hits.reduce(0) { $0 + $1.w }
        guard total > 0 else { return nil }
        return hits.reduce(0) { $0 + hypot($1.p.x - centre.x, $1.p.y - centre.y) * $1.w } / total
    }

    /// The farthest a pixel of weight over `threshold` lies from `centre`,
    /// looking no farther than `within`.
    func reach(from centre: CGPoint, within: CGFloat = 14, over threshold: CGFloat = 0.15, _ weight: PixelWeight) -> CGFloat {
        let area = CGRect(x: centre.x - within, y: centre.y - within, width: 2 * within, height: 2 * within)
        return weighed(in: area, weight).filter { $0.w > threshold }
            .map { hypot($0.p.x - centre.x, $0.p.y - centre.y) }.filter { $0 <= within }.max() ?? 0
    }

    /// The x of the one-point column holding the most weight: where a band
    /// is, untouched by a faint sliver elsewhere.
    func peakColumn(where keep: (CGPoint) -> Bool = { _ in true }, _ weight: PixelWeight) -> CGFloat? {
        var columns: [Int: CGFloat] = [:]
        for h in weighed(where: keep, weight) { columns[Int(h.p.x), default: 0] += h.w }
        return columns.max { $0.value < $1.value }.map { CGFloat($0.key) + 0.5 }
    }

    /// The middle of the box round every pixel in `rect` whose weight is
    /// over `threshold`: a ring's centre, whatever part of it is bright.
    func boxCentre(in rect: CGRect, over threshold: CGFloat, _ weight: PixelWeight) -> CGPoint? {
        let hits = weighed(in: rect, weight).filter { $0.w > threshold }.map(\.p)
        guard let minX = hits.map(\.x).min(), let maxX = hits.map(\.x).max(),
              let minY = hits.map(\.y).min(), let maxY = hits.map(\.y).max() else { return nil }
        return CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    /// The share of `samples` points along a path that are lit.
    func litShare(along points: [CGPoint], over threshold: CGFloat = 0.1, _ weight: PixelWeight) -> Double {
        guard !points.isEmpty else { return 0 }
        let lit = points.filter { let c = sample($0); return weight(c.r, c.g, c.b) > threshold }.count
        return Double(lit) / Double(points.count)
    }
}

enum MotionAngles {
    /// `b - a`, folded into -180...180.
    static func delta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
