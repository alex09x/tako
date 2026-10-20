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

/// Every change of state on every surface Core Animation draws: the new
/// state shows as the spec says, the old one leaves nothing behind, and a
/// one-off (the done pop and glint) fires on the change into it.
@Suite(.serialized) @MainActor
struct MotionTransitionMatrixTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let surface: MotionSpec.Surface
        let from: Tako.SurfaceState
        let to: Tako.SurfaceState
        let reduceMotion: Bool
        var testDescription: String {
            "\(surface) \(from.specName) → \(to.specName)\(reduceMotion ? " reduce-motion" : "")"
        }
    }

    static let cases: [Case] = MotionSpec.Surface.allCases.flatMap { surface in
        MotionSpec.states.flatMap { from in
            MotionSpec.states.filter { $0 != from }.flatMap { to in
                [false, true].map { Case(surface: surface, from: from, to: to, reduceMotion: $0) }
            }
        }
    }

    @Test(arguments: cases)
    func aChangeShowsTheNewStateAndNothingOfTheOld(_ c: Case) {
        let surface = MotionSurfaceHarness(c.surface, reduceMotion: c.reduceMotion)
        defer { surface.close() }
        surface.show(c.from)
        surface.show(c.to)
        let got = surface.effects()
        let want = MotionSpec.effects(on: c.surface, c.to, reduceMotion: c.reduceMotion, entered: true)
        #expect(got == want, "missing \(want.subtracting(got).sorted { $0.description < $1.description }), extra \(got.subtracting(want).sorted { $0.description < $1.description })")
    }

    // MARK: - Within a state

    @Test(arguments: [MotionSpec.Surface.pill, .row])
    func aNewPercentageMovesTheArcAndTheLineAndRebuildsNothing(_ kind: MotionSpec.Surface) throws {
        let surface = MotionSurfaceHarness(kind)
        defer { surface.close() }
        surface.show(.progress(0.2))
        let layer = try #require(surface.layer)
        let shade = try #require(layer.ringContainer.sublayers?.first { $0.name == "progressArc" })
        let arc = try #require(shade.mask as? CAShapeLayer)
        let line = try #require(layer.named(Tako.TabStatusLayer.LayerName.progressLine))
        let narrow = line.frame.width
        #expect(abs(arc.strokeEnd - 0.2) < 0.001)

        surface.show(.progress(0.7))
        #expect(layer.ringContainer.sublayers?.first { $0.name == "progressArc" } === shade, "the ring was rebuilt")
        #expect(abs(arc.strokeEnd - 0.7) < 0.001)
        #expect(line.frame.width > narrow * 3, "line \(narrow) -> \(line.frame.width)")
        // The line spans the surface less its insets, in proportion.
        let inset = kind == .row ? line.frame.minX : 0
        let span = (kind == .pill ? MotionSurfaceHarness.pillSize.width : layer.bounds.width) - 2 * inset
        #expect(abs(line.frame.width - span * 0.7) < 1, "line \(line.frame.width) of \(span)")
    }

    @Test func aLiveRingRipplesOncePerNewBurstWhileItFlows() throws {
        let surface = MotionSurfaceHarness(.pill)
        surface.show(.live(flowing: true), pulses: 0)
        let layer = try #require(surface.layer)
        let ripple = { layer.ringContainer.sublayers?.first { $0.name == "liveRipple" } }
        #expect(ripple()?.animation(forKey: "liveRipple") == nil, "a ripple before any output")

        surface.show(.live(flowing: true), pulses: 1)
        let first = try #require(ripple()?.animation(forKey: "liveRipple"))
        #expect(abs(first.duration - MotionSpec.rippleDuration) < 0.001)

        // The same count again is the same burst.
        ripple()?.removeAllAnimations()
        surface.show(.live(flowing: true), pulses: 1)
        #expect(ripple()?.animation(forKey: "liveRipple") == nil)
    }

    @Test(arguments: [false, true])
    func aQuietRingOrReducedMotionNeverRipples(_ reduceMotion: Bool) throws {
        let surface = MotionSurfaceHarness(.pill, reduceMotion: reduceMotion)
        surface.show(reduceMotion ? .live(flowing: true) : .live(flowing: false), pulses: 0)
        surface.show(reduceMotion ? .live(flowing: true) : .live(flowing: false), pulses: 3)
        let layer = try #require(surface.layer)
        let ripple = layer.ringContainer.sublayers?.first { $0.name == "liveRipple" }
        #expect(ripple != nil)
        #expect(ripple?.animation(forKey: "liveRipple") == nil)
    }

    @Test func aPausedRingDoesNotRippleNorCatchUpAfter() throws {
        let layer = Tako.TabStatusLayer()
        let rect = CGRect(origin: .zero, size: MotionSurfaceHarness.pillSize)
        layer.apply(state: .live(flowing: true), in: rect, hideRing: false, reduceMotion: false, paused: true, pulses: 0)
        layer.apply(state: .live(flowing: true), in: rect, hideRing: false, reduceMotion: false, paused: true, pulses: 4)
        let ripple = try #require(layer.ringContainer.sublayers?.first { $0.name == "liveRipple" })
        #expect(ripple.animation(forKey: "liveRipple") == nil)
        layer.apply(state: .live(flowing: true), in: rect, hideRing: false, reduceMotion: false, paused: false, pulses: 4)
        #expect(ripple.animation(forKey: "liveRipple") == nil, "caught up on a burst it did not show")
    }

    // MARK: - Pausing

    @Test(arguments: MotionSpec.states)
    func aHiddenSurfaceStandsStillAndGoesOnWhereItStopped(_ state: Tako.SurfaceState) {
        let layer = Tako.TabStatusLayer()
        let rect = CGRect(origin: .zero, size: MotionSurfaceHarness.pillSize)
        layer.apply(state: state, in: rect, hideRing: false, reduceMotion: false, paused: false)
        #expect(layer.speed == 1)
        let before = StatusLayerInventory.effects(of: layer)
        layer.apply(state: state, in: rect, hideRing: false, reduceMotion: false, paused: true)
        #expect(layer.speed == 0, "\(state.specName) still runs while hidden")
        // Paused, not torn down: the same motions are there to go on with.
        #expect(StatusLayerInventory.effects(of: layer) == before)
        layer.apply(state: state, in: rect, hideRing: false, reduceMotion: false, paused: false)
        #expect(layer.speed == 1)
        #expect(StatusLayerInventory.effects(of: layer) == before)
    }

    // MARK: - Reduce Motion turned on and off mid-state

    /// A pill's layer is told Reduce Motion at every draw; a row takes it
    /// when SwiftUI makes it again, which the state matrix covers.
    @Test(arguments: MotionSpec.states)
    func turningReduceMotionOnAndOffMidStateFollowsIt(_ state: Tako.SurfaceState) {
        let layer = Tako.TabStatusLayer()
        let rect = CGRect(origin: .zero, size: MotionSurfaceHarness.pillSize)
        layer.apply(state: state, in: rect, hideRing: false, reduceMotion: false, paused: false)
        layer.apply(state: state, in: rect, hideRing: false, reduceMotion: true, paused: false)
        #expect(StatusLayerInventory.effects(of: layer)
            == MotionSpec.effects(on: .pill, state, reduceMotion: true, entered: false), "\(state.specName) with motion reduced")
        layer.apply(state: state, in: rect, hideRing: false, reduceMotion: false, paused: false)
        #expect(StatusLayerInventory.effects(of: layer)
            == MotionSpec.effects(on: .pill, state, reduceMotion: false, entered: false), "\(state.specName) with motion back")
    }
}

/// The one-offs end by themselves: Core Animation takes them off when they
/// have run, and what stays is the state at rest.
@Suite(.serialized) @MainActor
struct MotionOneOffEndTests {
    @Test func thePopAndTheGlintAreTakenOffWhenTheyHaveRun() throws {
        let layer = Tako.TabStatusLayer()
        let rect = CGRect(origin: .zero, size: MotionSurfaceHarness.pillSize)
        layer.apply(state: .working, in: rect, hideRing: false, reduceMotion: false, paused: false)
        layer.apply(state: .done, in: rect, hideRing: false, reduceMotion: false, paused: false)
        let pop = try #require(layer.ringContainer.animation(forKey: "donePop"))
        let glint = try #require(layer.named(Tako.TabStatusLayer.LayerName.doneGlint)?.animation(forKey: "doneFlash"))
        #expect(pop.isRemovedOnCompletion)
        #expect(glint.isRemovedOnCompletion)
        #expect(abs(pop.duration - MotionSpec.popDuration) < 0.001)
        #expect(abs(glint.duration - MotionSpec.glintDuration) < 0.001)
        #expect(pop.repeatCount == 0 && glint.repeatCount == 0, "a one-off repeats")
    }
}
