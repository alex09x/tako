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

/// Every Spec 1b motion follows the design's CSS keyframes (Sessions UI,
/// §7), in the sidebar and Overview (SwiftUI, from `LivingAnimationState`)
/// and on the pill tabs (Core Animation, from `TabStatusLayer`) alike. The
/// tabs' frame export steps its layers with the SwiftUI functions, so it
/// never showed what the tabs' own animations do; these read them.
@Suite(.serialized)
@MainActor
struct MotionCurveTests {
    private typealias L = LivingAnimationState

    private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

    // MARK: - The design's keyframes

    @Test func thePopShrinksOvershootsAndSettlesOnTheDesignsBeats() {
        // @keyframes pop { 0% 1, 27.3% .55, 63.6% 1.25, 100% 1 } over .704s
        for (ms, scale) in [(0.0, 1.0), (192, 0.55), (448, 1.25), (704, 1.0)] {
            #expect(near(Double(L.donePopScale(elapsed: ms / 1000)), scale), "pop at \(ms) ms")
        }
        #expect(L.donePopScale(elapsed: 0.8) == 1)
    }

    @Test func theShakeSwingsTwoPointsEachWayAndStops() {
        for (ms, dx) in [(0.0, 0.0), (64, -2), (128, 2), (192, -2), (256, 2), (320, -1), (448, 0)] {
            #expect(near(Double(L.failedShakeOffset(elapsed: ms / 1000)), dx), "shake at \(ms) ms")
        }
        #expect(L.failedShakeOffset(elapsed: 0.5) == 0)
    }

    @Test func theWaitingHaloBlinkAndBreatheRepeatEvery1600ms() {
        let start = L.haloMetrics(at: 0)
        #expect(near(Double(start.scale), 1) && near(start.opacity, 0.75))
        let end = L.haloMetrics(at: 1.599)
        #expect(near(Double(end.scale), 2.1, 0.02) && near(end.opacity, 0, 0.02))
        for (ms, opacity) in [(0.0, 1.0), (800, 0.25), (1600, 1.0)] {
            #expect(near(L.blinkOpacity(at: ms / 1000), opacity), "blink at \(ms) ms")
        }
        for (ms, s) in [(0.0, 0.0), (800, 1.0), (1600, 0.0)] {
            #expect(near(L.breatheFactor(at: ms / 1000), s), "breathe at \(ms) ms")
        }
    }

    @Test func theSpinnerTurnsIn900msAndTheCometIn2200ms() {
        #expect(near(L.spinDegrees(at: 0.45), 180))
        #expect(near(L.spinDegrees(at: 0.9 + 0.225), 90))
        #expect(near(L.cometDegrees(at: 1.1), 180))
        #expect(near(L.cometDegrees(at: 2.2 + 0.55), 90))
    }

    @Test func theGlintSweepsWithEaseOutIn960ms() {
        #expect(DoneGlint.progress(elapsed: 0) == 0)
        // ease-out: past half way at half time, never back.
        let half = Double(DoneGlint.progress(elapsed: 0.48) ?? 0)
        #expect(half > 0.6 && half < 0.8)
        #expect(DoneGlint.progress(elapsed: 0.96) == nil)
    }

    // MARK: - The tabs move as the sidebar does

    private let pill = CGRect(x: 0, y: 0, width: 160, height: 28)

    /// A tab's status layer that has just entered `state` from `previous`.
    private func tab(_ state: Tako.SurfaceState, after previous: Tako.SurfaceState = .idle) -> Tako.TabStatusLayer {
        let layer = Tako.TabStatusLayer()
        layer.apply(state: previous, in: pill, hideRing: false, reduceMotion: false, paused: false)
        layer.apply(state: state, in: pill, hideRing: false, reduceMotion: false, paused: false)
        return layer
    }

    private func times(over seconds: TimeInterval) -> [TimeInterval] {
        Array(stride(from: 0.0, to: seconds, by: 0.023))
    }

    private func number(_ layer: CALayer, _ keyPath: String) -> Double {
        (layer.value(forKeyPath: keyPath) as? NSNumber)?.doubleValue ?? .nan
    }

    /// Two angles in radians, as the same direction.
    private func sameAngle(_ a: Double, _ b: Double) -> Bool {
        abs(atan2(sin(a - b), cos(a - b))) < 0.02
    }

    @Test func theSpinnerAndCometTurnAsTheSidebarsDo() throws {
        let clock = AnimationClock()
        let layer = tab(.working)
        // The layers are y-up: a negative angle turns clockwise, as a growing
        // SwiftUI angle does.
        let spin = try #require(layer.animationInTree(forKey: "spin")).animation
        let ts = times(over: 1.9)
        for (t, p) in zip(ts, clock.sample(spin, at: ts)) {
            #expect(sameAngle(number(p, "transform.rotation.z"), -L.spinDegrees(at: t) * .pi / 180), "spinner at \(t)")
        }
        let comet = try #require(layer.animationInTree(forKey: "cometSpin")).animation
        let tc = times(over: 4.5)
        for (t, p) in zip(tc, clock.sample(comet, at: tc)) {
            #expect(sameAngle(number(p, "transform.rotation.z"), -L.cometDegrees(at: t) * .pi / 180), "comet at \(t)")
        }
    }

    @Test func theWaitingHaloDotAndBorderBreatheAsTheSidebarsDo() throws {
        let clock = AnimationClock()
        let layer = tab(.waiting)
        let ts = times(over: 3.3)
        let halo = try #require(layer.animationInTree(forKey: "halo")).animation
        for (t, p) in zip(ts, clock.sample(halo, at: ts)) {
            let m = L.haloMetrics(at: t)
            #expect(near(number(p, "transform.scale"), Double(m.scale)), "halo scale at \(t)")
            #expect(near(Double(p.opacity), m.opacity), "halo opacity at \(t)")
        }
        let blink = try #require(layer.animationInTree(forKey: "blink")).animation
        for (t, p) in zip(ts, clock.sample(blink, at: ts)) {
            #expect(near(Double(p.opacity), L.blinkOpacity(at: t)), "dot at \(t)")
        }
        // The border: Claw at .40 ... .95, as a sidebar row's (§3.2).
        let breathe = try #require(layer.animationInTree(forKey: "breathe")).animation
        for (t, p) in zip(ts, clock.sample(breathe, on: CAShapeLayer(), at: ts)) {
            let alpha = Double((p as? CAShapeLayer)?.strokeColor?.alpha ?? -1)
            #expect(near(alpha, 0.40 + 0.55 * L.breatheFactor(at: t)), "border at \(t)")
        }
    }

    @Test func doneTabPopsAndGlintsAsTheSidebarsDo() throws {
        let clock = AnimationClock()
        let layer = tab(.done, after: .working)
        // Both taken before sampling: a flush ends a one-shot on a layer outside a window.
        let pop = try #require(layer.animationInTree(forKey: "donePop")).animation
        let glint = try #require(layer.firstInTree(DoneGlintLayer.self))
        let sweep = try #require(glint.animation(forKey: "doneFlash"))
        let ts = times(over: 1.0)
        for (t, p) in zip(ts, clock.sample(pop, at: ts)) {
            #expect(near(number(p, "transform.scale"), Double(L.donePopScale(elapsed: t))), "pop at \(t)")
        }
        for (t, p) in zip(ts, clock.sample(sweep, at: ts)) {
            guard let k = DoneGlint.progress(elapsed: t) else { continue }
            #expect(abs(p.position.x - glint.x(at: k)) < 0.5, "glint at \(t)")
        }
    }

    @Test func failedTabShakesAsTheSidebarsRowDoes() throws {
        let clock = AnimationClock()
        let layer = tab(.failed, after: .working)
        let shake = try #require(layer.animationInTree(forKey: "failedShake")).animation
        let ts = times(over: 0.6)
        for (t, p) in zip(ts, clock.sample(shake, at: ts)) {
            #expect(near(number(p, "transform.translation.x"), Double(L.failedShakeOffset(elapsed: t)), 0.03), "shake at \(t)")
        }
    }

    @Test func aLiveRippleGrowsAndFadesWithEaseOutIn300ms() throws {
        let clock = AnimationClock()
        let layer = Tako.TabStatusLayer()
        layer.apply(state: .live(flowing: true), in: pill, hideRing: false, reduceMotion: false, paused: false, pulses: 0)
        layer.apply(state: .live(flowing: true), in: pill, hideRing: false, reduceMotion: false, paused: false, pulses: 1)
        let ripple = try #require(layer.animationInTree(forKey: "liveRipple")).animation
        let ts = times(over: 0.3)
        for (t, p) in zip(ts, clock.sample(ripple, at: ts)) {
            // SwiftUI's .easeOut, which LiveRingRipple uses, is CSS ease-out.
            let k = CSSTiming.easeOut(t / LiveRingStyle.rippleDuration)
            #expect(near(number(p, "transform.scale"), 1 + Double(LiveRingStyle.rippleScale - 1) * k), "ripple scale at \(t)")
            #expect(near(Double(p.opacity), LiveRingStyle.rippleOpacity * (1 - k)), "ripple opacity at \(t)")
        }
    }
}
