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
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), theme: blinking)
        XCTAssertTrue(view.isBlinkStateVisibleForTesting)

        let lit = try XCTUnwrap(view.blinkTimer)
        XCTAssertEqual(lit.fireDate.timeIntervalSinceNow, 0.72, accuracy: 0.05, "lit for")

        lit.fire()
        try await waitFor { !view.isBlinkStateVisibleForTesting }
        let out = try XCTUnwrap(view.blinkTimer)
        XCTAssertFalse(out === lit, "the next phase has a timer of its own")
        XCTAssertEqual(out.fireDate.timeIntervalSinceNow, 0.48, accuracy: 0.05, "out for")

        out.fire()
        try await waitFor { view.isBlinkStateVisibleForTesting }
        let again = try XCTUnwrap(view.blinkTimer)
        XCTAssertEqual(again.fireDate.timeIntervalSinceNow, 0.72, accuracy: 0.05, "lit again for")
        XCTAssertEqual(CursorBlink.phaseDuration(lit: true) + CursorBlink.phaseDuration(lit: false), 1.2, accuracy: 1e-9)
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
