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
import Testing
@testable import Tako

/// The tab strip's own motion. A failed pill shakes whole, as a sidebar row
/// does (it used to shake its ring and leave its title still), and the
/// workspace chip slides to the width its attention badge needs instead of
/// every pill jumping by it the moment a tab fails or waits.
@Suite(.serialized)
@MainActor
struct TabStripMotionTests {
    private let key = ObjectIdentifier(NSObject())

    @Test func aPillThatFailsShakesOnTheDesignsCurveFromThatMoment() {
        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.shakeOffset(for: key, state: .failed, previous: .working, now: 100) == 0)
        for t in stride(from: 0.02, to: 0.448, by: 0.03) {
            let dx = bar.shakeOffset(for: key, state: .failed, previous: .failed, now: 100 + t)
            #expect(abs(dx - LivingAnimationState.failedShakeOffset(elapsed: t)) < 0.001, "at \(t)")
        }
        #expect(bar.shakeOffset(for: key, state: .failed, previous: .failed, now: 100.5) == 0)
        #expect(bar.failedSince.isEmpty)
    }

    @Test func aPillAlreadyFailedOrSeenFirstAsFailedDoesNotShake() {
        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.shakeOffset(for: key, state: .failed, previous: nil, now: 0) == 0)
        #expect(bar.shakeOffset(for: key, state: .failed, previous: .failed, now: 0.064) == 0)
        _ = bar.shakeOffset(for: key, state: .failed, previous: .working, now: 1)
        // Leaving failed mid-shake stops it.
        #expect(bar.shakeOffset(for: key, state: .working, previous: .failed, now: 1.064) == 0)
        #expect(bar.failedSince.isEmpty)
    }

    @Test func theChipSlidesToItsNewWidthInsteadOfJumping() {
        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.displayedChipWidth(target: 80, now: 10) == 80)
        #expect(bar.displayedChipWidth(target: 100, now: 20) == 80)
        let mid = bar.displayedChipWidth(target: 100, now: 20.075)
        #expect(mid > 85 && mid < 100, "half way: \(mid)")
        #expect(bar.displayedChipWidth(target: 100, now: 20.16) == 100)
        #expect(bar.chipSlide == nil)
        // Back down when the badge goes, from wherever it is.
        #expect(bar.displayedChipWidth(target: 80, now: 30) == 100)
        #expect(bar.displayedChipWidth(target: 80, now: 30.2) == 80)
    }

    /// Every tab is a window; those behind the selected one are laid out on
    /// every refresh but never drawn, so a slide there would never end.
    @Test func aHiddenTabWindowTakesTheNewWidthAtOnceAndRunsNoFrames() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bar = Tako.TabBarView(frame: .zero)
        window.contentView?.addSubview(bar)
        #expect(!window.isVisible)
        _ = bar.displayedChipWidth(target: 80, now: 0)
        #expect(bar.displayedChipWidth(target: 100, now: 1) == 100)
        #expect(bar.chipSlide == nil)
        _ = bar.shakeOffset(for: key, state: .failed, previous: .working, now: 2)
        #expect(bar.motionLink == nil)
    }

    @Test func motionThatRanItsTimeEndsUndrawn() {
        let bar = Tako.TabBarView(frame: .zero)
        _ = bar.displayedChipWidth(target: 80, now: 0)
        _ = bar.displayedChipWidth(target: 100, now: 1)
        _ = bar.shakeOffset(for: key, state: .failed, previous: .working, now: 1)
        #expect(bar.expireMotion(now: 1.1))
        #expect(!bar.expireMotion(now: 1.5))
        #expect(bar.chipSlide == nil && bar.failedSince.isEmpty)
    }

    @Test func aChangeMidSlideStartsFromWhereTheChipIs() {
        let bar = Tako.TabBarView(frame: .zero)
        _ = bar.displayedChipWidth(target: 80, now: 0)
        _ = bar.displayedChipWidth(target: 100, now: 1)
        let there = bar.displayedChipWidth(target: 100, now: 1.05)
        #expect(bar.displayedChipWidth(target: 80, now: 1.05) == there)
    }

    @Test func enablingReduceMotionStopsASlideAndShakeAlreadyInProgress() {
        withMotionOn {
            let motion = LivingAnimationState.shared
            let bar = Tako.TabBarView(frame: .zero)
            _ = bar.displayedChipWidth(target: 80, now: 1)
            _ = bar.displayedChipWidth(target: 100, now: 2)
            _ = bar.shakeOffset(for: key, state: .failed, previous: .working, now: 2)
            #expect(bar.chipSlide != nil && !bar.failedSince.isEmpty)

            motion.reduceMotionSource = { true }
            motion.refreshReduceMotion()
            #expect(bar.displayedChipWidth(target: 100, now: 2.05) == 100)
            #expect(bar.shakeOffset(for: key, state: .failed, previous: .failed, now: 2.05) == 0)
            #expect(bar.chipSlide == nil && bar.failedSince.isEmpty)
        }
    }

    @Test func turningReduceMotionBackOffDoesNotResumeAnInterruptedShake() {
        withMotionOn {
            let scene = StripScene(tabs: 1, motionOn: false)
            defer { scene.close() }
            let bar = scene.shown
            _ = bar.shakeOffset(for: key, state: .failed, previous: .working, now: 2)
            #expect(!bar.failedSince.isEmpty)
            LivingAnimationState.shared.reduceMotionSource = { true }
            LivingAnimationState.shared.refreshReduceMotion()
            LivingAnimationState.shared.reduceMotionSource = { false }
            LivingAnimationState.shared.refreshReduceMotion()
            #expect(bar.shakeOffset(for: key, state: .failed, previous: .failed, now: 2.05) == 0)
        }
    }

    @Test func turningReduceMotionBackOffDoesNotResumeAnInterruptedTabTransition() throws {
        try withMotionOn {
            let scene = StripScene(tabs: 2, motionOn: false)
            defer { scene.close() }
            let tab = scene.windows[1]
            let rest = try #require(scene.frame(of: tab))
            scene.group.transitions.tabAppeared(tab)
            scene.now += 0.04
            let growing = try #require(scene.frame(of: tab))
            #expect(growing.width < rest.width)
            LivingAnimationState.shared.reduceMotionSource = { true }
            LivingAnimationState.shared.refreshReduceMotion()
            LivingAnimationState.shared.reduceMotionSource = { false }
            LivingAnimationState.shared.refreshReduceMotion()
            let after = try #require(scene.frame(of: tab))
            #expect(abs(after.width - rest.width) < 0.5, "the interrupted transition resumed")
        }
    }
}
