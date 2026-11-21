/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// The Mac's view: the iOS surface run (scripts/test-ios-surface.sh) leaves it out.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import XCTest
@testable import TakoCoreUI

/// The cursor blinks as the Terminal UI design has it: once every 1.2 s,
/// lit for 60 % of it. It blinked every second, half on, half off.
final class CursorBlinkCadenceTests: XCTestCase {
    @MainActor
    func testTheCursorIsLitFor720msThenOutFor480ms() async throws {
        var blinking = TerminalTheme.takoDefault
        blinking.cursorBlink = true
        let began = Date()
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), theme: blinking)
        let mounted = Date()
        XCTAssertTrue(view.isBlinkStateVisibleForTesting)

        let lit = try XCTUnwrap(view.blinkTimer)
        assertDeadline(lit, duration: 0.72, scheduledBetween: began, and: mounted)

        let firstFire = Date()
        lit.fire()
        try await waitFor { !view.isBlinkStateVisibleForTesting }
        let firstObserved = Date()
        let out = try XCTUnwrap(view.blinkTimer)
        XCTAssertFalse(out === lit, "the next phase has a timer of its own")
        assertDeadline(out, duration: 0.48, scheduledBetween: firstFire, and: firstObserved)

        let secondFire = Date()
        out.fire()
        try await waitFor { view.isBlinkStateVisibleForTesting }
        let secondObserved = Date()
        let again = try XCTUnwrap(view.blinkTimer)
        assertDeadline(again, duration: 0.72, scheduledBetween: secondFire, and: secondObserved)
        XCTAssertEqual(CursorBlink.phaseDuration(lit: true), 0.72, accuracy: 1e-9)
        XCTAssertEqual(CursorBlink.phaseDuration(lit: false), 0.48, accuracy: 1e-9)
        XCTAssertEqual(CursorBlink.phaseDuration(lit: true) + CursorBlink.phaseDuration(lit: false), 1.2, accuracy: 1e-9)
    }

    /// The phase is scheduled between firing and observing its main-actor
    /// callback. Time spent waiting to observe it is not part of its duration.
    /// Keep the original 50 ms tolerance, measured from that scheduling window.
    private func assertDeadline(_ timer: Timer, duration: TimeInterval,
                                scheduledBetween start: Date, and end: Date,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(timer.fireDate.timeIntervalSince(start), duration - 0.05, file: file, line: line)
        XCTAssertLessThanOrEqual(timer.fireDate.timeIntervalSince(end), duration + 0.05, file: file, line: line)
    }

    @MainActor
    func testATimerReplacedMeanwhileDoesNotBlink() async throws {
        var blinking = TerminalTheme.takoDefault
        blinking.cursorBlink = true
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), theme: blinking)
        let stale = try XCTUnwrap(view.blinkTimer)
        view.updateBlinkTimer()
        let current = try XCTUnwrap(view.blinkTimer)
        stale.fire()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(view.isBlinkStateVisibleForTesting, "a stale timer blinked the cursor")
        XCTAssertTrue(view.blinkTimer === current, "a stale timer started a second chain")
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition() {
            guard Date() < deadline else { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
#endif
