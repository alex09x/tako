/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest
@testable import TakoCoreUI

/// The blink the phone's cursor runs on (Mobile UI: "мигание 1.2s (60% on
/// / 40% off)"), held here on the Mac: the phone blinked every second, half
/// on, half off.
@MainActor
final class CursorBlinkerTests: XCTestCase {
    func testItIsLit720msThenOut480msThenLitAgain() throws {
        var redraws = 0
        let blinker = CursorBlinker(shouldBlink: { true }, changed: { redraws += 1 })
        defer { blinker.stop() }
        blinker.restart()
        XCTAssertTrue(blinker.isLit)
        let lit = try XCTUnwrap(blinker.timer)
        XCTAssertEqual(lit.fireDate.timeIntervalSinceNow, 0.72, accuracy: 0.05, "lit for")

        lit.fire()
        XCTAssertFalse(blinker.isLit)
        XCTAssertEqual(redraws, 1)
        let out = try XCTUnwrap(blinker.timer)
        XCTAssertFalse(out === lit, "each phase has a timer of its own")
        XCTAssertEqual(out.fireDate.timeIntervalSinceNow, 0.48, accuracy: 0.05, "out for")

        out.fire()
        XCTAssertTrue(blinker.isLit)
        XCTAssertEqual(redraws, 2)
        XCTAssertEqual(try XCTUnwrap(blinker.timer).fireDate.timeIntervalSinceNow, 0.72, accuracy: 0.05, "lit again for")
    }

    func testATimerReplacedMeanwhileChangesNothing() throws {
        let blinker = CursorBlinker(shouldBlink: { true }, changed: {})
        defer { blinker.stop() }
        blinker.restart()
        let stale = try XCTUnwrap(blinker.timer)
        blinker.restart()
        let current = try XCTUnwrap(blinker.timer)
        stale.fire()
        XCTAssertTrue(blinker.isLit, "a stale timer blinked the cursor")
        XCTAssertTrue(blinker.timer === current, "a stale timer started a second chain")
    }

    func testHeldOutputKeepsThePhaseAndTheChainGoesOn() throws {
        var redraws = 0
        let blinker = CursorBlinker(shouldBlink: { true }, holdsStill: { true }, changed: { redraws += 1 })
        defer { blinker.stop() }
        blinker.restart()
        let lit = try XCTUnwrap(blinker.timer)
        lit.fire()
        XCTAssertTrue(blinker.isLit)
        XCTAssertEqual(redraws, 0)
        XCTAssertFalse(try XCTUnwrap(blinker.timer) === lit)
    }

    func testACursorThatDoesNotBlinkStaysLitAndStoppingEndsTheChain() throws {
        var blinks = false
        let blinker = CursorBlinker(shouldBlink: { blinks }, changed: {})
        blinker.restart()
        XCTAssertNil(blinker.timer)
        XCTAssertTrue(blinker.isLit)
        blinks = true
        blinker.restart()
        let lit = try XCTUnwrap(blinker.timer)
        blinker.stop()
        XCTAssertNil(blinker.timer)
        XCTAssertFalse(lit.isValid)
    }
}
