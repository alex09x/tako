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

    // MARK: - Kinetic Deceleration Tests

    func testKineticDecelerationVelocityThreshold() {
        // Below minimum threshold (80.0 pt/s default)
        let subZero = TerminalKineticDeceleration(initialVelocity: 0)
        XCTAssertFalse(subZero.isDecelerating)
        XCTAssertEqual(subZero.velocity, 0)

        let subPositive = TerminalKineticDeceleration(initialVelocity: 79.9)
        XCTAssertFalse(subPositive.isDecelerating)
        XCTAssertEqual(subPositive.velocity, 0)

        let subNegative = TerminalKineticDeceleration(initialVelocity: -79.9)
        XCTAssertFalse(subNegative.isDecelerating)
        XCTAssertEqual(subNegative.velocity, 0)

        // At or above threshold
        let atThreshold = TerminalKineticDeceleration(initialVelocity: 80.0)
        XCTAssertTrue(atThreshold.isDecelerating)
        XCTAssertEqual(atThreshold.velocity, 80.0)

        let negThreshold = TerminalKineticDeceleration(initialVelocity: -80.0)
        XCTAssertTrue(negThreshold.isDecelerating)
        XCTAssertEqual(negThreshold.velocity, -80.0)

        let active = TerminalKineticDeceleration(initialVelocity: 1200.0)
        XCTAssertTrue(active.isDecelerating)
        XCTAssertEqual(active.velocity, 1200.0)
    }

    func testKineticDecelerationMonotonicDecay() {
        var dec = TerminalKineticDeceleration(initialVelocity: 2500.0)
        XCTAssertTrue(dec.isDecelerating)

        let dt: TimeInterval = 1.0 / 60.0
        let cellH: Double = 20.0

        var prevVelocity = dec.velocity
        var stepCount = 0
        var totalLines = 0

        while dec.isDecelerating {
            let result = dec.step(deltaTime: dt, cellHeight: cellH)
            if let (lines, direction) = result {
                XCTAssertEqual(direction, .up)
                XCTAssertGreaterThanOrEqual(lines, 1)
                totalLines += lines
            }

            if dec.isDecelerating {
                XCTAssertLessThan(dec.velocity, prevVelocity, "Velocity must decay monotonically each step")
                XCTAssertGreaterThan(dec.velocity, 0)
                prevVelocity = dec.velocity
            }
            stepCount += 1
            XCTAssertLessThan(stepCount, 500, "Deceleration must terminate within bounded steps")
        }

        XCTAssertFalse(dec.isDecelerating)
        XCTAssertEqual(dec.velocity, 0)
        XCTAssertGreaterThan(totalLines, 0, "Deceleration must have produced lines")
    }

    func testKineticDecelerationTerminalStopAndZeroResidual() {
        var dec = TerminalKineticDeceleration(initialVelocity: 600.0)
        let dt: TimeInterval = 1.0 / 60.0
        let cellH: Double = 18.0

        while dec.isDecelerating {
            _ = dec.step(deltaTime: dt, cellHeight: cellH)
        }

        XCTAssertFalse(dec.isDecelerating)
        XCTAssertEqual(dec.velocity, 0)
        XCTAssertEqual(dec.accumulatedPoints, 0, "Terminal stop must clear sub-line residual")

        // Further steps return nil
        XCTAssertNil(dec.step(deltaTime: dt, cellHeight: cellH))
    }

    func testKineticDecelerationReciprocalDirections() {
        let initialSpeed: Double = 1800.0
        let cellH: Double = 20.0
        let dt: TimeInterval = 1.0 / 60.0

        var forwardDec = TerminalKineticDeceleration(initialVelocity: initialSpeed)
        var reverseDec = TerminalKineticDeceleration(initialVelocity: -initialSpeed)

        var forwardSteps: [(lines: Int, direction: TerminalPanDirection)] = []
        var reverseSteps: [(lines: Int, direction: TerminalPanDirection)] = []

        var totalForwardLines = 0
        var totalReverseLines = 0

        while forwardDec.isDecelerating || reverseDec.isDecelerating {
            if let f = forwardDec.step(deltaTime: dt, cellHeight: cellH) {
                forwardSteps.append(f)
                totalForwardLines += f.lines
            }
            if let r = reverseDec.step(deltaTime: dt, cellHeight: cellH) {
                reverseSteps.append(r)
                totalReverseLines += r.lines
            }
        }

        XCTAssertEqual(totalForwardLines, totalReverseLines, "Total forward and reverse lines must be exactly identical")
        XCTAssertEqual(forwardSteps.count, reverseSteps.count, "Step count with emissions must match")

        for i in 0..<forwardSteps.count {
            XCTAssertEqual(forwardSteps[i].lines, reverseSteps[i].lines, "Per-step line counts must match at step \(i)")
            XCTAssertEqual(forwardSteps[i].direction, .up)
            XCTAssertEqual(reverseSteps[i].direction, .down)
        }
    }

    func testKineticDecelerationMaxVelocityClamping() {
        let extremePositive = TerminalKineticDeceleration(initialVelocity: 15000.0)
        XCTAssertEqual(extremePositive.velocity, TerminalKineticDeceleration.defaultMaxVelocity)

        let extremeNegative = TerminalKineticDeceleration(initialVelocity: -12000.0)
        XCTAssertEqual(extremeNegative.velocity, -TerminalKineticDeceleration.defaultMaxVelocity)
    }

    func testKineticDecelerationCancellation() {
        var dec = TerminalKineticDeceleration(initialVelocity: 2000.0)
        XCTAssertTrue(dec.isDecelerating)
        _ = dec.step(deltaTime: 1.0 / 60.0, cellHeight: 20.0)
        XCTAssertGreaterThan(dec.velocity, 0)

        dec.cancel()
        XCTAssertFalse(dec.isDecelerating)
        XCTAssertEqual(dec.velocity, 0)
        XCTAssertEqual(dec.accumulatedPoints, 0)
        XCTAssertNil(dec.step(deltaTime: 1.0 / 60.0, cellHeight: 20.0))
    }
}
