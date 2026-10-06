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
import XCTest
@testable import TakoCoreUI

extension TakoTerminalNSViewTests {

    func testPresentationInvalidationDoesNotReenterDrive() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            view.needsDisplay = true

            XCTAssertTrue(view.redrawPending)
        }
    }

    func testPresentationPauseRetainsDamageAndPresentsOnlyAfterResume() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.isPresentationPaused = true
            view.feed(data: Data("arrived while hidden".utf8))

            XCTAssertTrue(view.isPresentationPaused)
            XCTAssertTrue(view.redrawPending)
            XCTAssertTrue(view.plainText(startRow: 0, maxRows: 1).contains("arrived while hidden"))

            let fetchedWhilePaused = view.frameFetchCount
            view.redrawNow()
            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, fetchedWhilePaused, "paused draw paths must not fetch a frame")

            view.isPresentationPaused = false
            XCTAssertFalse(view.isPresentationPaused)
            XCTAssertTrue(view.redrawPending, "damage accrued while paused is still owed")

            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, fetchedWhilePaused + 1)
            XCTAssertFalse(view.redrawPending)

            drawForTesting(view)
            XCTAssertEqual(
                view.frameFetchCount,
                fetchedWhilePaused + 1,
                "one coalesced presentation debt must fetch exactly one frame")
        }
    }

    func testPresentationPauseTransitionsAreIdempotent() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.isPresentationPaused = true
            view.isPresentationPaused = true
            view.feed(data: Data("coalesced".utf8))

            let fetchedWhilePaused = view.frameFetchCount
            view.displayLinkFired()
            XCTAssertEqual(view.frameFetchCount, fetchedWhilePaused)

            view.isPresentationPaused = false
            view.isPresentationPaused = false
            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, fetchedWhilePaused + 1)
            XCTAssertFalse(view.redrawPending)
        }
    }

    func testPresentationRateLimitAttachedCPUFallbackUsesOneShotAndRetainsLatestDebt() {
        MainActor.assumeIsolated {
            var now: TimeInterval = 1
            var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: .borderless,
                backing: .buffered,
                defer: false)
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            window.contentView = view
            view.setPresentationRateLimitClockForTesting { now }
            view.setPresentationThrottleSchedulerForTesting { delay, work in
                scheduled.append((delay, work))
            }
            view.maximumPresentationFramesPerSecond = 5

            view.scheduleRedraw()
            drawForTesting(view)
            let first = view.frameFetchCount
            view.scheduleRedraw()
            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, first)
            XCTAssertTrue(view.redrawPending, "a capped draw must remain owed")
            XCTAssertTrue(view.hasPresentationThrottleForTesting)
            XCTAssertEqual(scheduled.count, 1, "rapid attached damage gets exactly one coalesced wakeup")
            XCTAssertEqual(scheduled[0].delay, 0.2, accuracy: 0.000_001)

            now += 0.2
            scheduled.removeFirst().work.perform()
            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, first + 1)
            XCTAssertFalse(view.redrawPending)
            XCTAssertFalse(view.hasPresentationThrottleForTesting, "the final delayed frame leaves no idle wakeup")

            // Explicit AppKit paint after the deadline cancels the stale
            // one-shot instead of retaining a needless idle callback.
            view.scheduleRedraw()
            XCTAssertEqual(scheduled.count, 1)
            now += 0.2
            drawForTesting(view)
            XCTAssertTrue(scheduled.removeFirst().work.isCancelled)
            XCTAssertFalse(view.hasPresentationThrottleForTesting)

            // Pause and detach preserve debt but cancel the outstanding work.
            view.scheduleRedraw()
            let pausedWork = scheduled.removeFirst().work
            view.isPresentationPaused = true
            XCTAssertTrue(pausedWork.isCancelled)
            XCTAssertFalse(view.hasPresentationThrottleForTesting)
            view.isPresentationPaused = false
            XCTAssertEqual(scheduled.count, 1)
            let resumedWork = scheduled.removeFirst().work

            window.contentView = nil
            XCTAssertTrue(resumedWork.isCancelled)
            XCTAssertFalse(view.hasPresentationThrottleForTesting)
            XCTAssertTrue(view.redrawPending, "detach retains the latest unsatisfied frame")

            window.contentView = view
            XCTAssertEqual(scheduled.count, 1, "reattach resumes the retained debt")
            now += 0.2
            scheduled.removeFirst().work.perform()
            drawForTesting(view)
            XCTAssertFalse(view.redrawPending)

            view.scheduleRedraw()
            let rateChangeWork = scheduled.removeFirst().work
            view.maximumPresentationFramesPerSecond = 10
            XCTAssertTrue(rateChangeWork.isCancelled)
            XCTAssertEqual(scheduled.count, 1)
            let clearWork = scheduled.removeFirst().work
            view.maximumPresentationFramesPerSecond = nil
            XCTAssertTrue(clearWork.isCancelled)
            drawForTesting(view)
            XCTAssertFalse(view.redrawPending)
            XCTAssertFalse(view.hasPresentationThrottleForTesting, "an idle attached surface retains no scheduled work")
        }
    }

    func testPresentationRateLimitDestroyCancelsAttachedOneShot() {
        MainActor.assumeIsolated {
            let now: TimeInterval = 1
            var scheduled: [DispatchWorkItem] = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: .borderless,
                backing: .buffered,
                defer: false)
            weak var releasedView: TakoTerminalNSView?

            autoreleasepool {
                let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
                releasedView = view
                window.contentView = view
                view.setPresentationRateLimitClockForTesting { now }
                view.setPresentationThrottleSchedulerForTesting { _, work in scheduled.append(work) }
                view.maximumPresentationFramesPerSecond = 5
                drawForTesting(view)
                view.scheduleRedraw()
                XCTAssertEqual(scheduled.count, 1)
                window.contentView = nil
            }

            XCTAssertTrue(scheduled[0].isCancelled)
            XCTAssertNil(releasedView, "a detached destroyed view must not retain a throttle callback")
        }
    }

    func testPresentationPauseSuspendsAndRestoresExactlyOneBlinkTimer() throws {
        try MainActor.assumeIsolated {
            var blinking = TerminalTheme.takoDefault
            blinking.cursorBlink = true
            let view = TakoTerminalNSView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                theme: blinking)
            let originalTimer = try XCTUnwrap(view.blinkTimer)

            view.isPresentationPaused = true
            XCTAssertNil(view.blinkTimer)

            view.theme = blinking
            XCTAssertNil(view.blinkTimer, "theme updates must not wake a paused surface")

            view.isPresentationPaused = false
            let resumedTimer = try XCTUnwrap(view.blinkTimer)
            XCTAssertFalse(originalTimer === resumedTimer)

            view.isPresentationPaused = false
            XCTAssertTrue(resumedTimer === view.blinkTimer, "an idempotent resume must keep one timer")
        }
    }

    func testDisabledCursorBlinkOwnsNoTimerAcrossThemeChanges() {
        MainActor.assumeIsolated {
            var noBlink = TerminalTheme.takoDefault
            noBlink.cursorBlink = false
            let view = TakoTerminalNSView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                theme: noBlink)
            XCTAssertNil(view.blinkTimer)

            var blinking = noBlink
            blinking.cursorBlink = true
            view.theme = blinking
            XCTAssertNotNil(view.blinkTimer)

            view.theme = noBlink
            XCTAssertNil(view.blinkTimer)
            view.isPresentationPaused = true
            view.isPresentationPaused = false
            XCTAssertNil(view.blinkTimer, "resuming must not recreate a disabled blink timer")
        }
    }

    // MARK: - Accessibility & Teardown

}
