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
import Testing
@testable import Tako

/// The frames the motion tests read are the render server's: what is drawn
/// where, the right way up, and moving with the clock.
@Suite(.serialized) @MainActor
struct MotionLayerFramesTests {
    private let size = CGSize(width: 120, height: 28)

    private func pill(_ state: Tako.SurfaceState, reduceMotion: Bool = false) -> Tako.TabStatusLayer {
        let layer = Tako.TabStatusLayer()
        layer.apply(state: state, in: CGRect(origin: .zero, size: size), hideRing: false,
                    reduceMotion: reduceMotion, paused: false)
        LayerFrames.restartAnimations(in: layer)
        return layer
    }

    @Test func aFailedLineIsAtTheBottomOfTheFrame() {
        let frames = LayerFrames()
        let frame = frames.render(pill(.failed), size: size, at: 1)
        let bottom = frame.mass(in: CGRect(x: 20, y: 0, width: 80, height: 2.5), LayerFrame.redExcess)
        let top = frame.mass(in: CGRect(x: 20, y: 25.5, width: 80, height: 2.5), LayerFrame.redExcess)
        #expect(bottom > 20, "red at the bottom \(bottom)")
        #expect(top < 1, "red at the top \(top)")
    }

    @Test func theRingSitsAtTheLeftMiddle() throws {
        let frames = LayerFrames()
        let frame = frames.render(pill(.done), size: size, at: 2)
        let green = try #require(frame.centroid(over: 0.2, LayerFrame.greenExcess))
        #expect(abs(green.x - 15) < 1.5, "ring centre x \(green.x)")
        #expect(abs(green.y - 14) < 1.5, "ring centre y \(green.y)")
    }

    @Test func theCometMovesWithTheClock() throws {
        let frames = LayerFrames()
        let layer = pill(.working)
        // The ring is left out: the comet alone, round the border.
        let border = { (p: CGPoint) in p.x > 26 || p.y < 3 || p.y > 25 }
        func head(_ t: CFTimeInterval) throws -> CGPoint {
            let frame = frames.render(layer, size: size, at: t)
            let hits = frame.points(over: 0.25, LayerFrame.redExcess).filter { border($0.p) }
            let total = hits.reduce(0) { $0 + $1.w }
            try #require(total > 0, "no comet at \(t)")
            return CGPoint(x: hits.reduce(0) { $0 + $1.p.x * $1.w } / total, y: hits.reduce(0) { $0 + $1.p.y * $1.w } / total)
        }
        let a = try head(0.1), b = try head(0.65), c = try head(1.2)
        #expect(hypot(a.x - b.x, a.y - b.y) > 10, "\(a) -> \(b)")
        #expect(hypot(b.x - c.x, b.y - c.y) > 10, "\(b) -> \(c)")
        // A full turn later it is back.
        let d = try head(0.1 + 2.2)
        #expect(hypot(a.x - d.x, a.y - d.y) < 3, "\(a) vs a turn later \(d)")
    }
}
