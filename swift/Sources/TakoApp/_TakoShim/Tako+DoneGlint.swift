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
import SwiftUI

/// The "done" glint of Spec 1b, drawn the way the design's CSS draws it:
///
///     .shim::before { background: linear-gradient(100deg, transparent 30%,
///                     rgba(123,216,143,.26) 50%, transparent 70%);
///                     background-size: 250% 100%; animation: shimmer … }
///     @keyframes shimmer { 0% { background-position: 120% 0 }
///                          30%, 100% { background-position: -60% 0 } }
///
/// The gradient is a tile 2.5× the surface wide, repeated sideways, slid from
/// 120% to -60% over the first 0.96 s with ease-out. Its band never reaches a
/// tile's edge, so the glint has no hard edge anywhere on the surface.
enum DoneGlint {
    static let angleDegrees: Double = 100
    static let tileScale: CGFloat = 2.5
    static let peakAlpha: CGFloat = 0.26
    /// transparent 30% -> green 50% -> transparent 70%
    static let locations: [CGFloat] = [0.3, 0.5, 0.7]

    /// 0...1 through the sweep, or nil once it is over (the surface is quiet).
    static func progress(elapsed: TimeInterval) -> CGFloat? {
        guard elapsed >= 0, elapsed < 0.96 else { return nil }
        return CGFloat(CSSTiming.easeOut(elapsed * 1000.0 / 960.0))
    }

    /// Left edge of the tile at `progress`, in points from the surface's left
    /// edge: background-position p% puts it at (w - 2.5w) * p.
    static func tileOrigin(progress k: CGFloat, width w: CGFloat) -> CGFloat {
        let p = 1.2 + (-0.6 - 1.2) * k
        return (w - tileScale * w) * p
    }

    /// CSS gradient-line end points for a `g`×`h` tile, as unit coordinates
    /// with y growing downwards (SwiftUI's; flip y for an unflipped CALayer).
    static func unitEndpoints(tileWidth g: CGFloat, height h: CGFloat) -> (start: CGPoint, end: CGPoint) {
        let a = angleDegrees * .pi / 180
        let dx = CGFloat(sin(a)), dy = CGFloat(-cos(a))
        let length = abs(g * dx) + abs(h * dy)
        let hx = dx * length / 2 / max(g, 1), hy = dy * length / 2 / max(h, 1)
        return (CGPoint(x: 0.5 - hx, y: 0.5 - hy), CGPoint(x: 0.5 + hx, y: 0.5 + hy))
    }
}

extension DoneGlint {
    /// The same gradient for a CAGradientLayer, whose axial gradient runs
    /// perpendicular to start->end in the layer's *unit* space, not in points:
    /// on a wide, flat tile the CSS angle has to be undone per axis. Unit
    /// coordinates of an unflipped layer (y up).
    static func layerEndpoints(tileWidth g: CGFloat, height h: CGFloat) -> (start: CGPoint, end: CGPoint) {
        let a = angleDegrees * .pi / 180
        let dx = CGFloat(sin(a)), dy = CGFloat(-cos(a))
        let length = abs(g * dx) + abs(h * dy)
        let start = unitEndpoints(tileWidth: g, height: h).start
        // location(x, y) must be ((x, y) - S) . D / length in points.
        let k = length / (dx * dx * g * g + dy * dy * h * h)
        let end = CGPoint(x: start.x + k * dx * g, y: start.y + k * dy * h)
        return (CGPoint(x: start.x, y: 1 - start.y), CGPoint(x: end.x, y: 1 - end.y))
    }
}

/// The glint over a SwiftUI surface; the caller clips it to the surface's shape
/// and puts it behind the surface's content, as `::before` is.
struct DoneGlintView: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let g = DoneGlint.tileScale * w
            let ends = DoneGlint.unitEndpoints(tileWidth: g, height: h)
            let origin = DoneGlint.tileOrigin(progress: progress, width: w)
            let green = Color(nsColor: Tako.LivingTokens.ok).opacity(DoneGlint.peakAlpha)
            let none = Color(nsColor: Tako.LivingTokens.ok).opacity(0)
            ZStack(alignment: .topLeading) {
                ForEach(-1...1, id: \.self) { i in
                    LinearGradient(
                        stops: [
                            .init(color: none, location: DoneGlint.locations[0]),
                            .init(color: green, location: DoneGlint.locations[1]),
                            .init(color: none, location: DoneGlint.locations[2]),
                        ],
                        startPoint: UnitPoint(x: ends.start.x, y: ends.start.y),
                        endPoint: UnitPoint(x: ends.end.x, y: ends.end.y)
                    )
                    .frame(width: g, height: h)
                    .offset(x: origin + CGFloat(i) * g)
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

/// The same glint as Core Animation layers, for the pill tabs: three tiles in
/// a container that slides as background-position does.
final class DoneGlintLayer: CALayer {
    private let tiles = (0..<3).map { _ in CAGradientLayer() }
    private var surfaceWidth: CGFloat = 0

    override init() {
        super.init()
        anchorPoint = .zero
        let green = Tako.LivingTokens.ok.withAlphaComponent(DoneGlint.peakAlpha).cgColor
        // CSS mixes `transparent` premultiplied; a gradient layer does not, so
        // its ends are the same green at no alpha, not clear black.
        let none = Tako.LivingTokens.ok.withAlphaComponent(0).cgColor
        for tile in tiles {
            tile.colors = [none, green, none]
            tile.locations = DoneGlint.locations.map { NSNumber(value: Double($0)) }
            tile.contentsScale = 2.0
            addSublayer(tile)
        }
        contentsScale = 2.0
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Sizes the tiles for a surface of `size`.
    func layout(for size: CGSize) {
        surfaceWidth = size.width
        let g = DoneGlint.tileScale * size.width
        let ends = DoneGlint.layerEndpoints(tileWidth: g, height: size.height)
        bounds = CGRect(x: 0, y: 0, width: 3 * g, height: size.height)
        for (i, tile) in tiles.enumerated() {
            tile.frame = CGRect(x: CGFloat(i) * g, y: 0, width: g, height: size.height)
            tile.startPoint = ends.start
            tile.endPoint = ends.end
        }
        position = CGPoint(x: x(at: 0), y: 0)
    }

    /// The container's left edge at `progress`: the middle tile sits at the
    /// tile origin, one more on each side.
    func x(at progress: CGFloat) -> CGFloat {
        DoneGlint.tileOrigin(progress: progress, width: surfaceWidth) - DoneGlint.tileScale * surfaceWidth
    }
}
