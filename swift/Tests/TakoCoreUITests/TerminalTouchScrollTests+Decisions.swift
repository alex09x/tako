/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import XCTest
@testable import TakoCoreUI

extension TerminalTouchScrollTests {
    func testTouchScrollDecisionPrimaryScreenSendsMouseWheelWhenMouseTrackingActive() {
        let core = TakoCore(cols: 80, rows: 24)
        // Enable mouse tracking on primary screen without entering alternate screen (representative of Claude Code and interactive TUIs)
        core.feed(bytes: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let modes = core.modes()
        XCTAssertFalse(modes.alternateScreen, "Primary screen remains active")
        XCTAssertEqual(modes.mouseTracking, .normal)
        XCTAssertTrue(modes.mouseSgr)

        let col = 15
        let row = 8
        // Panning down (translation.y > 0) -> direction .up -> SGR wheel up (\e[<64;16;9M)
        let actionUp = TerminalTouchScrollDecision.decide(
            lines: 2,
            direction: .up,
            modes: modes,
            touchCol: col,
            touchRow: row,
            core: core
        )
        let expectedUpData = Data("\u{1b}[<64;16;9M\u{1b}[<64;16;9M".utf8)
        XCTAssertEqual(actionUp, .sendInput(expectedUpData))

        // Panning up (translation.y < 0) -> direction .down -> SGR wheel down (\e[<65;16;9M)
        let actionDown = TerminalTouchScrollDecision.decide(
            lines: 1,
            direction: .down,
            modes: modes,
            touchCol: col,
            touchRow: row,
            core: core
        )
        let expectedDownData = Data("\u{1b}[<65;16;9M".utf8)
        XCTAssertEqual(actionDown, .sendInput(expectedDownData))

        // Disabling mouse tracking returns to local primary screen scrollback
        core.feed(bytes: Data("\u{1b}[?1000l".utf8))
        let disabledModes = core.modes()
        XCTAssertFalse(disabledModes.alternateScreen)
        XCTAssertEqual(disabledModes.mouseTracking, .off)

        let actionAfterDisable = TerminalTouchScrollDecision.decide(
            lines: 3,
            direction: .up,
            modes: disabledModes,
            touchCol: col,
            touchRow: row,
            core: core
        )
        XCTAssertEqual(actionAfterDisable, .scrollViewportUp(lines: 3))
    }

    func testTouchScrollDecisionClaudeCodeModeCombinationsAndTransitions() {
        let core = TakoCore(cols: 80, rows: 24)
        // Actual mode sequence emitted by Claude Code and Ink-based TUIs:
        // Hide cursor (?25l), enable Normal (?1000h) and ButtonEvent (?1002h) mouse tracking, SGR format (?1006h), bracketed paste (?2004h)
        core.feed(bytes: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        let modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)
        XCTAssertEqual(modes.mouseTracking, .buttonEvent)
        XCTAssertTrue(modes.mouseSgr)
        XCTAssertTrue(modes.bracketedPaste)

        // Native vertical swipes in Claude Code produce SGR mouse wheel input
        let action = TerminalTouchScrollDecision.decide(
            lines: 2,
            direction: .down,
            modes: modes,
            touchCol: 20,
            touchRow: 10,
            core: core
        )
        let expectedData = Data("\u{1b}[<65;21;11M\u{1b}[<65;21;11M".utf8)
        XCTAssertEqual(action, .sendInput(expectedData))

        // When Claude exits and restores normal terminal mode:
        core.feed(bytes: Data("\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h".utf8))
        let restoredModes = core.modes()
        XCTAssertFalse(restoredModes.alternateScreen)
        XCTAssertEqual(restoredModes.mouseTracking, .off)

        let scrollbackAction = TerminalTouchScrollDecision.decide(
            lines: 4,
            direction: .up,
            modes: restoredModes,
            touchCol: 0,
            touchRow: 0,
            core: core
        )
        XCTAssertEqual(scrollbackAction, .scrollViewportUp(lines: 4))
    }

    func testTouchScrollDecisionMouseTrackingButtonEventAndAnyEventVariants() {
        let core = TakoCore(cols: 80, rows: 24)

        // 1002 ButtonEvent tracking
        core.feed(bytes: Data("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h".utf8))
        var modes = core.modes()
        XCTAssertEqual(modes.mouseTracking, .buttonEvent)
        let action1002 = TerminalTouchScrollDecision.decide(
            lines: 1,
            direction: .up,
            modes: modes,
            touchCol: 0,
            touchRow: 0,
            core: core
        )
        XCTAssertEqual(action1002, .sendInput(Data("\u{1b}[<64;1;1M".utf8)))

        // 1003 AnyEvent tracking
        core.feed(bytes: Data("\u{1b}[?1003h".utf8))
        modes = core.modes()
        XCTAssertEqual(modes.mouseTracking, .anyEvent)
        let action1003 = TerminalTouchScrollDecision.decide(
            lines: 1,
            direction: .down,
            modes: modes,
            touchCol: 0,
            touchRow: 0,
            core: core
        )
        XCTAssertEqual(action1003, .sendInput(Data("\u{1b}[<65;1;1M".utf8)))
    }

    func testTouchScrollDecisionZeroOrNegativeLinesReturnsNone() {
        let core = TakoCore(cols: 80, rows: 24)
        let modes = core.modes()

        XCTAssertEqual(
            TerminalTouchScrollDecision.decide(
                lines: 0,
                direction: .up,
                modes: modes,
                touchCol: 0,
                touchRow: 0,
                core: core
            ),
            .none
        )
        XCTAssertEqual(
            TerminalTouchScrollDecision.decide(
                lines: -5,
                direction: .down,
                modes: modes,
                touchCol: 0,
                touchRow: 0,
                core: core
            ),
            .none
        )
    }

    func testTouchScrollDecisionStrictReciprocityUnderClaudeMouseTracking() {
        let core = TakoCore(cols: 80, rows: 24)
        // Claude Code mode sequence on primary screen:
        // Hide cursor (?25l), Normal (?1000h), ButtonEvent (?1002h), SGR (?1006h), Bracketed paste (?2004h)
        core.feed(bytes: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        let modes = core.modes()
        XCTAssertFalse(modes.alternateScreen)
        XCTAssertEqual(modes.mouseTracking, .buttonEvent)
        XCTAssertTrue(modes.mouseSgr)

        let testLocations = [(col: 0, row: 0), (col: 19, row: 11), (col: 79, row: 23)]
        let testLineCounts = [1, 2, 5, 10, 25]

        for loc in testLocations {
            for lineCount in testLineCounts {
                let actionUp = TerminalTouchScrollDecision.decide(
                    lines: lineCount,
                    direction: .up,
                    modes: modes,
                    touchCol: loc.col,
                    touchRow: loc.row,
                    core: core
                )
                let actionDown = TerminalTouchScrollDecision.decide(
                    lines: lineCount,
                    direction: .down,
                    modes: modes,
                    touchCol: loc.col,
                    touchRow: loc.row,
                    core: core
                )

                guard case .sendInput(let dataUp) = actionUp,
                      case .sendInput(let dataDown) = actionDown else {
                    XCTFail("Both decisions must produce sendInput")
                    continue
                }

                let strUp = String(data: dataUp, encoding: .utf8) ?? ""
                let strDown = String(data: dataDown, encoding: .utf8) ?? ""

                let expectedCount = min(lineCount, TerminalTouchScrollDecision.maxLinesPerGestureCallback)
                let expectedCol = loc.col + 1
                let expectedRow = loc.row + 1

                let singleUpPattern = "\u{1b}[<64;\(expectedCol);\(expectedRow)M"
                let singleDownPattern = "\u{1b}[<65;\(expectedCol);\(expectedRow)M"

                let expectedUpStr = String(repeating: singleUpPattern, count: expectedCount)
                let expectedDownStr = String(repeating: singleDownPattern, count: expectedCount)

                XCTAssertEqual(strUp, expectedUpStr, "Upward decision must emit exactly \(expectedCount) WheelUp events at (\(expectedCol), \(expectedRow))")
                XCTAssertEqual(strDown, expectedDownStr, "Downward decision must emit exactly \(expectedCount) WheelDown events at (\(expectedCol), \(expectedRow))")
                XCTAssertEqual(dataUp.count, dataDown.count, "Reciprocal wheel data sizes must be identical")
            }
        }
    }


}
