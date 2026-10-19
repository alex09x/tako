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

/// The Overview's one timeline takes every frame while a card plays a
/// one-off motion, and 30 a second otherwise.
@Suite(.serialized)
@MainActor
struct OverviewFrameRateTests {
    private func items(_ statuses: [Tako.PaneStatus]) -> [PaneOverviewItem] {
        statuses.map { PaneOverviewItem(id: UUID(), title: "t", status: $0) }
    }

    @Test func aCardPlayingAOneOffTakesEveryFrameUntilItRests() {
        LivingAnimationState.shared.fixedTimeOverride = 0.3
        defer { LivingAnimationState.shared.fixedTimeOverride = nil }
        let remaining = PaneOverviewView.oneOffRemaining(of: items([.working, .done]), reduceMotion: false)
        #expect(remaining.map { abs($0 - 0.7) < 0.001 } == true)
        #expect(PaneOverviewView.minimumFrameInterval(oneOffRemaining: remaining) == nil)
    }

    @Test func lastingMotionsRestAndReducedMotionStayAtThirty() {
        LivingAnimationState.shared.fixedTimeOverride = 0.3
        defer { LivingAnimationState.shared.fixedTimeOverride = nil }
        #expect(PaneOverviewView.oneOffRemaining(of: items([.working, .needsApproval, .idle]), reduceMotion: false) == nil)
        #expect(PaneOverviewView.oneOffRemaining(of: items([.done, .error]), reduceMotion: true) == nil)
        LivingAnimationState.shared.fixedTimeOverride = 1.2
        #expect(PaneOverviewView.oneOffRemaining(of: items([.done, .error]), reduceMotion: false) == nil)
        #expect(PaneOverviewView.minimumFrameInterval(oneOffRemaining: nil) == 1.0 / 30.0)
    }
}
