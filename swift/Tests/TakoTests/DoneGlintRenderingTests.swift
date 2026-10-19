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
import Testing
@testable import Tako

/// The done glint as a window draws it. The sweep was three gradient tiles
/// moved with `.offset`; on macOS 15 a window drew every tile in view where
/// the surface is, so in a sidebar row the band stood still in the middle --
/// brighter while two tiles were in view -- and went out, while the pill
/// tabs' layers swept. ImageRenderer drew the offsets right (and macOS 26
/// does), so only a view drawn the way its window draws it (`cacheDisplay`)
/// shows what is on screen.
@Suite(.serialized)
@MainActor
struct DoneGlintRenderingTests {
    /// A sidebar row's surface.
    private let size = CGSize(width: 264, height: 46)

    /// Green over black in each column of the glint drawn at `progress`, in
    /// points from the surface's left edge.
    private func greenColumns(at progress: CGFloat) throws -> [(x: CGFloat, green: CGFloat)] {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: DoneGlintView(progress: progress).background(Color.black))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        return (0..<rep.pixelsWide).map { x in
            var green: CGFloat = 0
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                green += max(0, c.greenComponent - max(c.redComponent, c.blueComponent))
            }
            return ((CGFloat(x) + 0.5) / scale, green / CGFloat(rep.pixelsHigh))
        }
    }

    /// Where the band is brightest, or nil when no band shows.
    private func band(at progress: CGFloat) throws -> CGFloat? {
        let columns = try greenColumns(at: progress)
        let peak = try #require(columns.max { $0.green < $1.green })
        return peak.green > 0.005 ? peak.x : nil
    }

    @Test func theBandCrossesTheSurfaceWhereTheDesignPutsIt() throws {
        // The CSS band's centre is the tile's: 1.25 widths past its origin.
        for progress in [0.33, 0.4, 0.46] as [CGFloat] {
            let expected = DoneGlint.tileOrigin(progress: progress, width: size.width) + 1.25 * size.width
            let x = try #require(try band(at: progress), "no band at \(progress)")
            #expect(abs(x - expected) < 4, "band at \(x) for progress \(progress), the design has it at \(expected)")
        }
    }

    @Test func itMovesLeftToRightAllTheWay() throws {
        let xs = try [0.15, 0.25, 0.35, 0.45, 0.55, 0.65].map { try #require(try band(at: $0)) }
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 - 10 }, "\(xs)")
    }

    @Test func noBandBeforeItComesInOrAfterItLeaves() throws {
        #expect(try band(at: 0) == nil)
        #expect(try band(at: 0.9) == nil)
    }

    /// The one gradient over the surface is the tile's under every point of
    /// it: the same location, so the same band.
    @Test func theSurfaceGradientIsTheTileUnderIt() throws {
        func location(_ p: CGPoint, _ s: CGPoint, _ e: CGPoint) -> CGFloat {
            let d = CGPoint(x: e.x - s.x, y: e.y - s.y)
            return ((p.x - s.x) * d.x + (p.y - s.y) * d.y) / (d.x * d.x + d.y * d.y)
        }
        for (w, h) in [(CGFloat(264), CGFloat(46)), (139.4, 28), (340, 245)] {
            let g = DoneGlint.tileScale * w
            let ends = DoneGlint.unitEndpoints(tileWidth: g, height: h)
            for progress in stride(from: CGFloat(0.05), to: 1, by: 0.05) {
                let origin = DoneGlint.tileOrigin(progress: progress, width: w)
                // The tiles that put any of their band over the surface.
                let shown = (-1...1).filter { i in
                    let x = origin + CGFloat(i) * g
                    let s = CGPoint(x: x + ends.start.x * g, y: ends.start.y * h), e = CGPoint(x: x + ends.end.x * g, y: ends.end.y * h)
                    let corners = [CGPoint.zero, CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)].map { location($0, s, e) }
                    return corners.max()! > DoneGlint.locations[0] && corners.min()! < DoneGlint.locations[2]
                }
                #expect(shown.count <= 1)
                let band = DoneGlint.visibleBand(progress: progress, size: CGSize(width: w, height: h))
                guard let i = shown.first else { #expect(band == nil); continue }
                let b = try #require(band)
                let x = origin + CGFloat(i) * g
                let s = CGPoint(x: x + ends.start.x * g, y: ends.start.y * h), e = CGPoint(x: x + ends.end.x * g, y: ends.end.y * h)
                let bs = CGPoint(x: b.start.x * w, y: b.start.y * h), be = CGPoint(x: b.end.x * w, y: b.end.y * h)
                for p in [CGPoint(x: 0, y: 0), CGPoint(x: w / 3, y: h / 2), CGPoint(x: w, y: h)] {
                    #expect(abs(location(p, bs, be) - location(p, s, e)) < 0.0001)
                }
            }
        }
    }
}
