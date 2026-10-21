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

/// A frame exported at a fixed time (fixedTimeOverride: the frame dumps and
/// GIFs the design is compared against) stands in the design's pose at that
/// time: the spinner and comet turned, the waiting border breathed, a done
/// ring popped, a failed pill shaken -- by the design's numbers, not the
/// layer's own.
@Suite(.serialized) @MainActor
struct MotionSnapshotPhaseTests {
    private let pill = CGRect(x: 0, y: 0, width: 140, height: 28)

    private func layer(_ state: Tako.SurfaceState) -> Tako.TabStatusLayer {
        let layer = Tako.TabStatusLayer()
        layer.apply(state: .idle, in: pill, hideRing: false, reduceMotion: false, paused: false)
        layer.apply(state: state, in: pill, hideRing: false, reduceMotion: false, paused: false)
        return layer
    }

    private func turn(_ t: CATransform3D) -> Double { atan2(Double(t.m12), Double(t.m11)) }
    private func sameAngle(_ a: Double, _ b: Double) -> Bool { abs(atan2(sin(a - b), cos(a - b))) < 0.02 }

    @Test(arguments: [0.1, 0.3, 0.45, 0.7, 1.3])
    func aWorkingFrameTurnsTheSpinnerAndTheCometAsTheDesignDoes(_ t: Double) throws {
        let l = layer(.working)
        l.applySnapshotPhase(at: t)
        let spin = try #require(l.ringContainer.sublayers?.first { $0.name == "workingSpin" })
        // Clockwise on screen: a negative angle in a layer's space.
        #expect(sameAngle(turn(spin.transform), -2 * .pi * t / MotionSpec.spinnerTurn), "spinner at \(t)")
        let comet = try #require(l.animationInTree(forKey: "cometSpin")?.layer)
        #expect(sameAngle(turn(comet.transform), -2 * .pi * t / MotionSpec.cometTurn), "comet at \(t)")
    }

    @Test func aWaitingFrameBreathesFromFortyToNinetyFivePercent() throws {
        let l = layer(.waiting)
        func alpha(_ t: Double) throws -> CGFloat {
            l.applySnapshotPhase(at: t)
            let border = try #require(l.firstInTree(CAShapeLayer.self, named: "breathe"))
            return NSColor(cgColor: try #require(border.strokeColor))?.alphaComponent ?? -1
        }
        #expect(abs(try alpha(0) - MotionSpec.breatheStrokeAlpha.lowerBound) < 0.02)
        #expect(abs(try alpha(MotionSpec.breatheHalf) - MotionSpec.breatheStrokeAlpha.upperBound) < 0.02)
    }

    /// "свечение 16px 30 %": CSS blur 16 px is a shadow radius of 8 pt, and the glow breathes to 30 %.
    @Test func theWaitingGlowIsSixteenPixelsAtThirtyPercent() throws {
        let l = layer(.waiting)
        let glow = try #require(l.animationInTree(forKey: "breatheGlow")?.layer ?? l.firstInTree(CALayer.self, named: "breatheGlow"))
        #expect(glow.shadowRadius == MotionSpec.breatheGlowRadius, "glow radius \(glow.shadowRadius)")
        let breath = try #require(l.animationInTree(forKey: "breatheGlow")?.animation as? CABasicAnimation)
        #expect((breath.toValue as? NSNumber)?.floatValue == MotionSpec.breatheGlowOpacity.upperBound)
    }

    @Test func aDoneFramePopsOnTheDesignsBeatsAndAFailedOneShakes() {
        let done = layer(.done)
        for (beat, scale) in zip(MotionSpec.popKeyTimes, MotionSpec.popValues) {
            done.applySnapshotPhase(at: 5, doneElapsed: beat * MotionSpec.popDuration)
            #expect(abs(done.ringContainer.transform.m11 - scale) < 0.02, "pop at beat \(beat)")
        }
        let failed = layer(.failed)
        // CSS shake: 0, 2, 4, 6, 8, 10 and 14 % of 3.2 s.
        let beats = [0, 0.02, 0.04, 0.06, 0.08, 0.10, 0.14].map { $0 * 3.2 }
        for (i, dx) in MotionSpec.shakeOffsets.enumerated() {
            failed.applySnapshotPhase(at: 5, failedElapsed: beats[i])
            #expect(abs(failed.transform.m41 - dx) < 0.05, "shake step \(i)")
        }
    }
}

private extension CALayer {
    func firstInTree<L: CALayer>(_ type: L.Type, named name: String) -> L? {
        if let me = self as? L, me.name == name { return me }
        for sub in sublayers ?? [] { if let found = sub.firstInTree(type, named: name) { return found } }
        return nil
    }
}
