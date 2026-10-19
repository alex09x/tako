/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// Reading motion out of recorded frames: how often a region is redrawn and
// the longest it went without one, where a glint's band is, which way a
// spinner's head points, how wide a ring's disc is and where it sits.

import AppKit

extension Crop {
    func point(_ x: Int, _ y: Int) -> CGPoint {
        CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
    }

    /// Green above red and blue: the done green over Tako's dark surfaces.
    static func green(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat { max(0, g - max(r, b)) }
    /// Red above green and blue: Ember, Claw and the failed red.
    static func red(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat { max(0, r - max(g, b)) }

    /// The pixels whose `weight` is over `threshold`, in points.
    func points(over threshold: CGFloat, _ weight: (CGFloat, CGFloat, CGFloat) -> CGFloat,
                within area: CGRect? = nil) -> [(p: CGPoint, w: CGFloat)] {
        var out: [(CGPoint, CGFloat)] = []
        for y in 0..<height {
            for x in 0..<width {
                let p = point(x, y)
                if let area, !area.contains(p) { continue }
                let c = rgb(x, y)
                let w = weight(c.r, c.g, c.b)
                if w > threshold { out.append((p, w)) }
            }
        }
        return out
    }

    /// The column where `weight` summed down the column is largest, past `skip` points, or nil when it is all dark.
    /// Smoothed over 9 px first: a glint's band is broad and flat-topped, and its
    /// raw maximum wanders a few pixels from frame to frame.
    func peakColumn(_ weight: (CGFloat, CGFloat, CGFloat) -> CGFloat, skip: CGFloat, floor: CGFloat) -> CGFloat? {
        var sums = [CGFloat](repeating: 0, count: width)
        for x in 0..<width {
            for y in 0..<height { let c = rgb(x, y); sums[x] += weight(c.r, c.g, c.b) }
            sums[x] /= CGFloat(height)
        }
        var best: (x: CGFloat, sum: CGFloat)?
        for x in 0..<width where point(x, 0).x > skip {
            let window = sums[max(0, x - 4)...min(width - 1, x + 4)]
            let smooth = window.reduce(0, +) / CGFloat(window.count)
            if smooth > (best?.sum ?? floor) { best = (point(x, 0).x, smooth) }
        }
        return best?.x
    }
}

func boundingBox(_ points: [(p: CGPoint, w: CGFloat)]) -> CGRect? {
    guard let first = points.first?.p else { return nil }
    return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1.p, size: .zero)) }
}

/// The frames inside `window` (ms) whose `region` crop differs from the frame before.
func changes(_ frames: [Frame], _ region: String, in window: ClosedRange<Double>) -> [Frame] {
    var out: [Frame] = []
    var previous: Data?
    for f in frames {
        guard let crop = f.crops[region] else { continue }
        if previous != crop.bytes, window.contains(f.ms) { out.append(f) }
        previous = crop.bytes
    }
    return out
}

struct Cadence: CustomStringConvertible {
    let fps: Double
    let longestGap: Double
    let redraws: Int
    var description: String { String(format: "%.0f fps, longest gap %.0f ms", fps, longestGap) }
}

/// How often `region` was redrawn inside `window`, and the longest it waited.
func cadence(_ frames: [Frame], _ region: String, in window: ClosedRange<Double>) -> Cadence {
    let times = changes(frames, region, in: window).map(\.ms)
    let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
    guard !gaps.isEmpty else { return Cadence(fps: 0, longestGap: window.upperBound - window.lowerBound, redraws: times.count) }
    return Cadence(fps: 1000 / gaps[gaps.count / 2], longestGap: gaps.last!, redraws: times.count)
}

/// Degrees from `centre` to `p`, clockwise from 3 o'clock on screen.
func degrees(_ p: CGPoint, around centre: CGPoint) -> Double {
    Double(atan2(p.y - centre.y, p.x - centre.x)) * 180 / .pi
}

/// Degrees per second a spinner's head turns (clockwise positive), fitted over
/// the brightest Ember pixel of each redraw.
func spinRate(_ frames: [Frame], _ region: String, centre: CGPoint, in window: ClosedRange<Double>) -> Double? {
    var samples: [(t: Double, a: Double)] = []
    var last: Double?
    for f in changes(frames, region, in: window) {
        guard let crop = f.crops[region],
              let head = crop.points(over: 0.05, Crop.red).filter({ hypot($0.p.x - centre.x, $0.p.y - centre.y) < 9 }).max(by: { $0.w < $1.w })
        else { continue }
        var a = degrees(head.p, around: centre)
        if let last { while a - last > 180 { a -= 360 }; while a - last < -180 { a += 360 } }
        last = a
        samples.append((f.ms / 1000, a))
    }
    guard samples.count > 4 else { return nil }
    let mt = samples.map(\.t).reduce(0, +) / Double(samples.count)
    let ma = samples.map(\.a).reduce(0, +) / Double(samples.count)
    let num = samples.map { ($0.t - mt) * ($0.a - ma) }.reduce(0, +)
    let den = samples.map { ($0.t - mt) * ($0.t - mt) }.reduce(0, +)
    return den > 0 ? num / den : nil
}

/// Where the done glint's band is, at each redraw that shows its peak: a
/// peak against either end of the search is a band still coming in or
/// already leaving, whose real peak lies outside.
func bandTrack(_ frames: [Frame], _ region: String, skip: CGFloat, in window: ClosedRange<Double>) -> [(ms: Double, x: CGFloat)] {
    changes(frames, region, in: window).compactMap { f in
        guard let crop = f.crops[region], let x = crop.peakColumn(Crop.green, skip: skip, floor: 0.01),
              x > skip + 3, x < CGFloat(crop.width) / crop.scale - 3 else { return nil }
        return (f.ms, x)
    }
}

/// The disc of `weight` around a ring at each redraw: its width and centre x.
func discs(_ frames: [Frame], _ region: String, _ weight: @escaping (CGFloat, CGFloat, CGFloat) -> CGFloat,
           in window: ClosedRange<Double>) -> [(ms: Double, box: CGRect)] {
    changes(frames, region, in: window).compactMap { f in
        f.crops[region].flatMap { boundingBox($0.points(over: 0.15, weight)) }.map { (f.ms, $0) }
    }
}

/// Where the failed ring's disc sits at each redraw, and the centre of the
/// title's first 34 pt right of it, if the crop holds them. The thin failed
/// line along the surface's foot is left out by taking only rows near the
/// disc's top.
func shakeTrack(_ frames: [Frame], _ region: String, discLeftOf limit: CGFloat = .infinity,
                in window: ClosedRange<Double>) -> [(ms: Double, disc: CGFloat, title: CGFloat?)] {
    changes(frames, region, in: window).compactMap { f in
        guard let crop = f.crops[region] else { return nil }
        // Left of `limit`: a failed pill also shows a red unread dot at its far end.
        let red = crop.points(over: 0.15, Crop.red).filter { $0.p.x < limit }
        guard let top = red.map(\.p.y).min(),
              let disc = boundingBox(red.filter { $0.p.y < top + 13 }), disc.width > 8 else { return nil }
        // The title: light, unsaturated pixels just right of the disc,
        // weighed by how light -- its edge alone moves with antialiasing.
        let light = crop.points(over: 0.3) { r, g, b in min(r, g, b) }
            .filter { $0.p.x > disc.maxX + 2 && $0.p.x < disc.maxX + 36 }
        let weight = light.map { $0.w - 0.3 }.reduce(0, +)
        let title = weight > 1 ? zip(light, light.map { $0.w - 0.3 }).map { $0.p.x * $1 }.reduce(0, +) / weight : nil
        return (f.ms, disc.midX, title)
    }
}
