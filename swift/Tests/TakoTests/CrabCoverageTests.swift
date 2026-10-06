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

    @Test func colorForEachState() {
        #expect(Tako.CrabState.succeeded.color == Tako.Brand.ok)
        #expect(Tako.CrabState.failed(code: nil).color == Tako.Brand.error)
        #expect(Tako.CrabState.ghost.color == Tako.Brand.dim)
        #expect(Tako.CrabState.idle.color == Tako.Brand.ember)
        #expect(Tako.CrabState.running.color == Tako.Brand.ember)
        #expect(Tako.CrabState.attention.color == Tako.Brand.ember)
        #expect(Tako.CrabState.reconnecting.color == Tako.Brand.ember)
    }

    @Test @MainActor func commandShorterThanThresholdEndsIdleWithoutFlashingGreen() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(1)
        tracker.commandEnded(exitCode: 0)
        #expect(tracker.state == .idle)
        #expect(tracker.elapsedLabel == nil)
    }

    @Test @MainActor func commandLongerThanThresholdSucceedsAndLingers() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(5)
        tracker.tick()
        #expect(tracker.state == .running)
        #expect(tracker.elapsedLabel != nil)

        tracker.commandEnded(exitCode: 0)
        #expect(tracker.state == .succeeded)
        #expect(tracker.elapsedLabel == nil)
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

    @Test @MainActor func durationLabelFormatting() {
        #expect(Tako.CrabTracker.durationLabel(1.2) == "1.2s")
        #expect(Tako.CrabTracker.durationLabel(9.5) == "9.5s")
        #expect(Tako.CrabTracker.durationLabel(45) == "45s")
        #expect(Tako.CrabTracker.durationLabel(65) == "1m 05s")
        #expect(Tako.CrabTracker.durationLabel(125) == "2m 05s")
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

// MARK: - CrabView drawing + animation state machine

@Suite
struct CrabViewCoverageTests {
    @MainActor private func draw(_ view: Tako.CrabView) {
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
    }

    /// Renders `view` into a real bitmap so pixels can be compared, per the
    /// task's prescribed technique for proving drawn state actually changed.
    @MainActor private func snapshot(_ view: NSView) -> NSBitmapImageRep {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("could not create a bitmap rep for \(view)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func bitmapsEqual(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              let da = a.bitmapData, let db = b.bitmapData
        else { return false }
        let length = a.bytesPerRow * a.pixelsHigh
        guard length == b.bytesPerRow * b.pixelsHigh else { return false }
        return memcmp(da, db, length) == 0
    }

    private func hasOpaquePixel(_ rep: NSBitmapImageRep) -> Bool {
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    return true
                }
            }
        }
        return false
    }

    @Test @MainActor func intrinsicContentSizeIsSixteenByFixteen() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        #expect(view.intrinsicContentSize == NSSize(width: 16, height: 16))
        #expect(!view.isFlipped)
    }

    @Test @MainActor func drawsWithoutUnreadDotByDefault() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        let defaultSnapshot = snapshot(view) // `unread` is false by default.

        let explicitlyOff = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        explicitlyOff.unread = false
        #expect(bitmapsEqual(defaultSnapshot, snapshot(explicitlyOff)))

        view.unread = true
        // Turning it on paints something the false-by-default render did not.
        #expect(!bitmapsEqual(defaultSnapshot, snapshot(view)))
    }

    @Test @MainActor func drawsWithUnreadDot() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        let before = snapshot(view)

        view.unread = true
        let after = snapshot(view)
        #expect(!bitmapsEqual(before, after))

        view.unread = false
        // Turning it back off restores the original pixels exactly.
        #expect(bitmapsEqual(before, snapshot(view)))
    }

    @Test @MainActor func settingSameStateTwiceDoesNotRestartAnimation() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.state = .running
        // Synchronous: the 0.2s leg-cycle timer cannot have ticked yet, so
        // this is deterministically the phase-0 frame.
        let phase0 = snapshot(view)

        var phase1: NSBitmapImageRep?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            let current = snapshot(view)
            if !bitmapsEqual(current, phase0) {
                phase1 = current
                break
            }
        }
        guard let phase1 else {
            Issue.record("the running animation never ticked")
            return
        }

        // Re-assigning the same state must not restart the animation: the
        // phase the timer already reached has to survive the redundant set,
        // undisturbed (a restart would reset it back to phase 0).
        view.state = .running
        #expect(bitmapsEqual(snapshot(view), phase1))
    }

    @Test @MainActor func everyStateDrawsCleanly() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        var renders: [NSBitmapImageRep] = []
        for state: Tako.CrabState in [.idle, .running, .succeeded, .failed(code: 1), .attention, .reconnecting, .ghost] {
            view.state = state
            let image = snapshot(view)
            // Every state actually paints the crab's body, not a blank frame.
            #expect(hasOpaquePixel(image))
            renders.append(image)
        }
        // Succeeded and failed recolour the mark (Brand.ok vs Brand.error):
        // their renders must not coincidentally be pixel-identical.
        #expect(!bitmapsEqual(renders[2], renders[3]))
    }
}
