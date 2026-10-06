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
import Foundation
@testable import TakoCoreUI

final class TerminalTouchScrollTests: XCTestCase {

    func testTakoCoreModesTracksAlternateScreenAndMode1007() {
        let core = TakoCore(cols: 80, rows: 24)
        var modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)
        XCTAssertTrue(modes.alternateScroll)

        // 1049 alternate screen enter/leave
        core.feed(bytes: Data("\u{1b}[?1049h".utf8))
        modes = core.modes()
        XCTAssertTrue(modes.alternateScreen)
        core.feed(bytes: Data("\u{1b}[?1049l".utf8))
        modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)

        // 47 alternate screen enter/leave
        core.feed(bytes: Data("\u{1b}[?47h".utf8))
        modes = core.modes()
        XCTAssertTrue(modes.alternateScreen)
        core.feed(bytes: Data("\u{1b}[?47l".utf8))
        modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)

        // 1047 alternate screen enter/leave
        core.feed(bytes: Data("\u{1b}[?1047h".utf8))
        modes = core.modes()
        XCTAssertTrue(modes.alternateScreen)
        core.feed(bytes: Data("\u{1b}[?1047l".utf8))
        modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)

        // Mode 1007 toggle
        core.feed(bytes: Data("\u{1b}[?1007l".utf8))
        modes = core.modes()
        XCTAssertFalse(modes.alternateScroll)
        core.feed(bytes: Data("\u{1b}[?1007h".utf8))
        modes = core.modes()
        XCTAssertTrue(modes.alternateScroll)

        // Multiple private mode params in one sequence
        core.feed(bytes: Data("\u{1b}[?1049;1000;1006h".utf8))
        modes = core.modes()
        XCTAssertTrue(modes.alternateScreen)
        XCTAssertEqual(modes.mouseTracking, .normal)
        XCTAssertTrue(modes.mouseSgr)

        core.feed(bytes: Data("\u{1b}[?1007;1049l".utf8))
        modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)
        XCTAssertFalse(modes.alternateScroll)

        // Soft reset resets mode 1007 to default on
        core.feed(bytes: Data("\u{1b}[!p".utf8))
        modes = core.modes()
        XCTAssertTrue(modes.alternateScroll)

        // Split chunks across boundary
        core.feed(bytes: Data("\u{1b}[?10".utf8))
        modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)
        core.feed(bytes: Data("49h".utf8))
        modes = core.modes()
        XCTAssertTrue(modes.alternateScreen)

        // Full reset restores all defaults
        core.feed(bytes: Data("\u{1b}c".utf8))
        modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)
        XCTAssertTrue(modes.alternateScroll)
    }

    func testTouchScrollDecisionPrimaryScreenMovesLocalScrollback() {
        let core = TakoCore(cols: 80, rows: 24)
        let modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)

        // Panning down (translation > 0) -> scrolling up into history
        let actionUp = TerminalTouchScrollDecision.decide(
            lines: 3,
            direction: .up,
            modes: modes,
            touchCol: 0,
            touchRow: 0,
            core: core
        )
        XCTAssertEqual(actionUp, .scrollViewportUp(lines: 3))

        // Panning up (translation < 0) -> scrolling down toward live screen
        let actionDown = TerminalTouchScrollDecision.decide(
            lines: 2,
            direction: .down,
            modes: modes,
            touchCol: 0,
            touchRow: 0,
            core: core
        )
        XCTAssertEqual(actionDown, .scrollViewportDown(lines: 2))
    }

    func testTouchScrollDecisionAlternateScreenSendsArrowKeysWhenMode1007Active() {
        let core = TakoCore(cols: 80, rows: 24)
        core.feed(bytes: Data("\u{1b}[?1049h".utf8))
        let modes = core.modes()
        XCTAssertTrue(modes.alternateScreen)
        XCTAssertTrue(modes.alternateScroll)
        XCTAssertEqual(modes.mouseTracking, .off)

        // Normal cursor keys (DECCKM = false)
        let actionUp = TerminalTouchScrollDecision.decide(
            lines: 2,
            direction: .up,
            modes: modes,
            touchCol: 10,
            touchRow: 5,
            core: core
        )
        let expectedUpData = Data("\u{1b}[A\u{1b}[A".utf8)
        XCTAssertEqual(actionUp, .sendInput(expectedUpData))

        let actionDown = TerminalTouchScrollDecision.decide(
            lines: 1,
            direction: .down,
            modes: modes,
            touchCol: 10,
            touchRow: 5,
            core: core
        )
        let expectedDownData = Data("\u{1b}[B".utf8)
        XCTAssertEqual(actionDown, .sendInput(expectedDownData))

        // Application cursor keys (DECCKM = true, \e[?1h)
        core.feed(bytes: Data("\u{1b}[?1h".utf8))
        let appModes = core.modes()
        XCTAssertTrue(appModes.cursorKeyAppMode)
        XCTAssertTrue(appModes.alternateScreen)

        let actionAppUp = TerminalTouchScrollDecision.decide(
            lines: 1,
            direction: .up,
            modes: appModes,
            touchCol: 0,
            touchRow: 0,
            core: core
        )
        XCTAssertEqual(actionAppUp, .sendInput(Data("\u{1b}OA".utf8)))

        let actionAppDown = TerminalTouchScrollDecision.decide(
            lines: 2,
            direction: .down,
            modes: appModes,
            touchCol: 0,
            touchRow: 0,
            core: core
        )
        XCTAssertEqual(actionAppDown, .sendInput(Data("\u{1b}OB\u{1b}OB".utf8)))
    }

    func testTouchScrollDecisionAlternateScreenSendsMouseWheelWhenMouseTrackingActive() {
        let core = TakoCore(cols: 80, rows: 24)
        // Enter alternate screen and enable SGR mouse tracking: \e[?1049h\e[?1000h\e[?1006h
        core.feed(bytes: Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let modes = core.modes()
        XCTAssertTrue(modes.alternateScreen)
        XCTAssertEqual(modes.mouseTracking, .normal)
        XCTAssertTrue(modes.mouseSgr)

        let col = 10
        let row = 5
        // SGR coordinates are 1-based: col 10 -> 11, row 5 -> 6. WheelUp is button 64, WheelDown is 65.
        let actionUp = TerminalTouchScrollDecision.decide(
            lines: 2,
            direction: .up,
            modes: modes,
            touchCol: col,
            touchRow: row,
            core: core
        )
        let expectedUpData = Data("\u{1b}[<64;11;6M\u{1b}[<64;11;6M".utf8)
        XCTAssertEqual(actionUp, .sendInput(expectedUpData))

        let actionDown = TerminalTouchScrollDecision.decide(
            lines: 1,
            direction: .down,
            modes: modes,
            touchCol: col,
            touchRow: row,
            core: core
        )
        let expectedDownData = Data("\u{1b}[<65;11;6M".utf8)
        XCTAssertEqual(actionDown, .sendInput(expectedDownData))
    }

    func testTouchScrollDecisionAlternateScreenDoesNothingWhenMode1007Disabled() {
        let core = TakoCore(cols: 80, rows: 24)
        core.feed(bytes: Data("\u{1b}[?1049h\u{1b}[?1007l".utf8))
        let modes = core.modes()
        XCTAssertTrue(modes.alternateScreen)
        XCTAssertFalse(modes.alternateScroll)

        let action = TerminalTouchScrollDecision.decide(
            lines: 3,
            direction: .up,
            modes: modes,
            touchCol: 0,
            touchRow: 0,
            core: core
        )
        XCTAssertEqual(action, .none)
    }

    func testTouchScrollDecisionBoundsRepeatedWheelAndKeyEmissions() {
        let core = TakoCore(cols: 80, rows: 24)
        core.feed(bytes: Data("\u{1b}[?1049h".utf8))
        let modes = core.modes()
        XCTAssertTrue(modes.alternateScreen)
        XCTAssertTrue(modes.alternateScroll)

        let maxBound = TerminalTouchScrollDecision.maxLinesPerGestureCallback
        XCTAssertEqual(maxBound, 10)

        // 1. Arrow keys bounded at maxLinesPerGestureCallback
        let largeScrollAction = TerminalTouchScrollDecision.decide(
            lines: 50,
            direction: .up,
            modes: modes,
            touchCol: 0,
            touchRow: 0,
            core: core
        )
        let singleKeyUp = Data("\u{1b}[A".utf8)
        var expectedBoundedKeys = Data()
        for _ in 0..<maxBound {
            expectedBoundedKeys.append(singleKeyUp)
        }
        XCTAssertEqual(largeScrollAction, .sendInput(expectedBoundedKeys))

        // 2. Mouse wheel bounded at maxLinesPerGestureCallback
        core.feed(bytes: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let mouseModes = core.modes()
        let largeWheelAction = TerminalTouchScrollDecision.decide(
            lines: 100,
            direction: .down,
            modes: mouseModes,
            touchCol: 5,
            touchRow: 3,
            core: core
        )
        let singleWheelDown = Data("\u{1b}[<65;6;4M".utf8)
        var expectedBoundedWheel = Data()
        for _ in 0..<maxBound {
            expectedBoundedWheel.append(singleWheelDown)
        }
        XCTAssertEqual(largeWheelAction, .sendInput(expectedBoundedWheel))

        // 3. Normal small swipe lines (< maxBound) are preserved without truncation
        let normalSwipeAction = TerminalTouchScrollDecision.decide(
            lines: 3,
            direction: .down,
            modes: mouseModes,
            touchCol: 5,
            touchRow: 3,
            core: core
        )
        var expectedNormalWheel = Data()
        for _ in 0..<3 {
            expectedNormalWheel.append(singleWheelDown)
        }
        XCTAssertEqual(normalSwipeAction, .sendInput(expectedNormalWheel))
    }


}
