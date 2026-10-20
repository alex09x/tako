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
import Foundation
import SwiftUI
import Testing
@testable import Tako
import TakoKit

// MARK: - Crab state tracking

@Suite
struct CrabTrackerCoverageTests {
    @Test func priorityOrderMatchesDesignSpec() {
        let ordered: [Tako.CrabState] = [
            .reconnecting, .idle, .succeeded, .attention, .running, .failed(code: 1), .ghost,
        ]
        for (index, state) in ordered.enumerated() {
            #expect(state.priority == index)
        }
    }

    @Test @MainActor func commandShorterThanThresholdEndsIdleWithoutFlashingGreen() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(1)
        tracker.commandEnded(exitCode: 0)
        #expect(tracker.state == .idle)
        #expect(tracker.elapsed == nil)
    }

    @Test @MainActor func commandLongerThanThresholdSucceedsAndLingers() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(5)
        tracker.tick()
        #expect(tracker.state == .running)
        #expect(tracker.elapsed != nil)

        tracker.commandEnded(exitCode: 0)
        #expect(tracker.state == .succeeded)
        #expect(tracker.elapsed == nil)
    }

    @Test @MainActor func failedCommandHoldsUntilFocused() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(4)
        tracker.commandEnded(exitCode: 7)
        #expect(tracker.state == .failed(code: 7))

        tracker.focused()
        #expect(tracker.state == .idle)
    }

    @Test @MainActor func bellRingsAttentionButNeverDowngradesFailure() {
        let tracker = Tako.CrabTracker()
        tracker.commandEnded(exitCode: 3)
        #expect(tracker.state == .failed(code: 3))
        tracker.bellRang()
        // failed (priority 5) outranks attention (priority 3): stays failed.
        #expect(tracker.state == .failed(code: 3))

        let idleTracker = Tako.CrabTracker()
        idleTracker.bellRang()
        #expect(idleTracker.state == .attention)
    }

    @Test @MainActor func progressReportedSetsAndClears() {
        let tracker = Tako.CrabTracker()
        tracker.progressReported(state: 1, value: 42)
        #expect(tracker.progress == 42)
        tracker.progressReported(state: 0, value: nil)
        #expect(tracker.progress == nil)
    }

    @Test @MainActor func connectionLostAndReconnecting() {
        let tracker = Tako.CrabTracker()
        tracker.connectionLost()
        #expect(tracker.state == .ghost)
        #expect(tracker.unread)

        tracker.reconnecting()
        #expect(tracker.state == .reconnecting)
    }

    @Test @MainActor func tickBeforeThresholdDoesNotSetElapsedOrState() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(1)
        tracker.tick()
        #expect(tracker.state == .idle)
        #expect(tracker.elapsed == nil)
    }

    @Test @MainActor func tickWithoutAStartedCommandIsANoOp() {
        let tracker = Tako.CrabTracker()
        tracker.tick()
        #expect(tracker.state == .idle)
    }
}

// MARK: - CrabView: the classic strip's crab layer in the tab accessory

@Suite @MainActor
struct CrabViewCoverageTests {
    @Test func intrinsicContentSizeIsSixteenBySixteen() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        #expect(view.intrinsicContentSize == NSSize(width: 16, height: 16))
        #expect(!view.isFlipped)
    }

    @Test func itHostsACrabLayerThatFollowsItsStateAndUnreadDot() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        #expect(view.crab.superlayer === view.layer)
        #expect(view.crab.shownState == .idle)
        #expect(view.crab.unreadDot.isHidden)
        view.unread = true
        #expect(!view.crab.unreadDot.isHidden)
        view.state = .reconnecting
        #expect(view.crab.shownState == .reconnecting)
        #expect(view.crab.glyph.animation(forKey: Tako.CrabLayer.Key.pulse) != nil || LivingAnimationState.shared.reduceMotion)
    }

    @Test func settingTheSameStateAgainLeavesItsMotionRunning() throws {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.state = .running
        guard !LivingAnimationState.shared.reduceMotion else { return }
        let scuttle = try #require(view.crab.glyph.animation(forKey: Tako.CrabLayer.Key.scuttle))
        view.state = .running
        view.layout()
        #expect(view.crab.glyph.animation(forKey: Tako.CrabLayer.Key.scuttle) === scuttle)
    }
}
