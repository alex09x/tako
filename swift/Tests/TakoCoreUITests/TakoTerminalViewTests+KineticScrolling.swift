/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(UIKit)
import Foundation
import Metal
import QuartzCore
import UIKit
import XCTest
@testable import TakoCoreUI

@MainActor
extension TakoTerminalViewTests {
    // MARK: - Kinetic Momentum Scrolling Tests

    func testPreFixRegressionReleasedSwipeProducedZeroPostEndedMotionVsKineticMomentum() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        let history = (1...60).map { "History line \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertEqual(view.viewportOffset, 0)

        // 1. Drag forward 1 line
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(view.viewportOffset, 1)

        // 2. Pre-fix behavior on release with non-zero velocity:
        // In pre-fix code, pan.state = .ended simply reset accum to 0 with zero velocity inspection,
        // producing 0 post-ended motion.
        // With kinetic scrolling enabled, ending with velocity engages kinetic deceleration.
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1800.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling, "Released swipe with velocity must activate kinetic momentum")
        XCTAssertEqual(view.kineticVelocity, 1800.0)

        // Step 10 frames of 1/60s: viewport advances beyond the 1-line gesture drag
        var stepsWithProgress = 0
        for _ in 0..<10 {
            if view.stepKineticScroll(deltaTime: 1.0 / 60.0) {
                stepsWithProgress += 1
            }
        }
        XCTAssertGreaterThan(stepsWithProgress, 0, "Kinetic momentum must advance viewport across post-release frames")
        XCTAssertGreaterThan(view.viewportOffset, 1, "Viewport offset must be greater than initial drag distance (1)")
    }

    func testTakoTerminalViewKineticScrollPrimaryScreenMonotonicDecelerationToRest() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        let history = (1...120).map { "Row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertEqual(view.viewportOffset, 0)

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 2200.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)

        var lastOffset = view.viewportOffset
        var stepCount = 0
        while view.isKineticScrolling {
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
            XCTAssertGreaterThanOrEqual(view.viewportOffset, lastOffset, "Offset must monotonically increase during upward scroll")
            lastOffset = view.viewportOffset
            stepCount += 1
            XCTAssertLessThan(stepCount, 500, "Momentum must reach rest in bounded steps")
        }

        XCTAssertFalse(view.isKineticScrolling)
        XCTAssertEqual(view.kineticVelocity, 0)
        XCTAssertGreaterThan(view.viewportOffset, 20, "Swipe with 2200 pt/s must advance substantial scrollback rows")
    }

    func testTakoTerminalViewKineticScrollClampAtTailAndScrollbackTop() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        // 1. Tail clamp: starting at offset 5, swipe down toward live tail
        let history = (1...60).map { "Row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        view.scrollViewportUp(lines: 5)
        XCTAssertEqual(view.viewportOffset, 5)

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: -4000.0)) // Swiping up -> scrolling down toward tail
        _ = view.perform(panSel, with: pan)

        while view.isKineticScrolling {
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        }
        XCTAssertEqual(view.viewportOffset, 0, "Momentum must clamp exactly at tail (offset 0)")
        XCTAssertFalse(view.isKineticScrolling, "Momentum must halt upon reaching tail")

        // 2. Scrollback top clamp: starting at top of history, swipe up into history
        view.scrollViewportUp(lines: 60)
        let topOffset = view.viewportOffset
        XCTAssertEqual(topOffset, view.scrollbackLength)

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 4000.0)) // Swiping down -> scrolling up
        _ = view.perform(panSel, with: pan)

        // Stepping should immediately halt since viewport is already at maximum scrollback
        _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        XCTAssertFalse(view.isKineticScrolling, "Momentum must halt upon reaching maximum scrollback limit")
        XCTAssertEqual(view.viewportOffset, topOffset)
    }

    func testTakoTerminalViewKineticScrollNewGestureCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        let history = (1...60).map { "Row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 2000.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)
        _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        XCTAssertTrue(view.isKineticScrolling)

        // New gesture begins: cancels active kinetic momentum immediately
        pan.state = .began
        _ = view.perform(panSel, with: pan)

        XCTAssertFalse(view.isKineticScrolling, "New gesture began must cancel active kinetic scroll")
        XCTAssertEqual(view.kineticVelocity, 0)
    }

    func testTakoTerminalViewKineticScrollSelectionCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let longPressSel = Selector(("handleLongPress:"))
        let pan = MockPanGestureRecognizer()
        let longPress = MockLongPressGestureRecognizer()

        let history = (1...60).map { "Row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 2000.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)

        // User starts text selection via long press
        longPress.state = .began
        _ = view.perform(longPressSel, with: longPress)

        XCTAssertFalse(view.isKineticScrolling, "Starting selection must cancel active kinetic scroll")
    }

    func testTakoTerminalViewKineticScrollModeChangeCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        // Enter alternate screen with mouse tracking
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h".utf8))
        XCTAssertTrue(view.isAlternateScreen)

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1500.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)
        _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)

        // Application leaves alternate screen and disables mouse tracking
        view.feed(data: Data("\u{1b}[?1000l\u{1b}[?1049l".utf8))

        XCTAssertFalse(view.isKineticScrolling, "Terminal mode change must cancel active kinetic momentum")
        XCTAssertFalse(view.stepKineticScroll(deltaTime: 1.0 / 60.0), "Further steps must produce nothing")
    }

    func testTakoTerminalViewKineticScrollWindowDetachmentCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        view.feed(data: Data((1...60).map { "Row \($0)\r\n" }.joined().utf8))

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1500.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)

        // Detach from window
        view.willMove(toWindow: nil)
        XCTAssertFalse(view.isKineticScrolling, "Moving out of window must cancel kinetic momentum")
    }

    func testTakoTerminalViewKineticScrollAlternateScreenBoundedEmissionsAndOrdering() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellW = view.renderer.metrics.cellWidth
        let cellH = view.renderer.metrics.cellHeight

        // Claude mode sequence: SGR mouse tracking (?1000h, ?1002h, ?1006h)
        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        pan.setMockLocation(CGPoint(x: cellW * 10.0, y: cellH * 5.0)) // col 10 -> 11, row 5 -> 6

        // Upward scrollback swipe (finger down, velocity > 0)
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 2000.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)
        delegate.inputDataReceived = Data()

        var totalWheelEvents = 0
        let expectedSinglePacket = "\u{1b}[<64;11;6M"

        while view.isKineticScrolling {
            let previousCount = delegate.inputDataReceived.count
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
            let newBytes = delegate.inputDataReceived.dropFirst(previousCount)
            if !newBytes.isEmpty {
                let packetStr = String(data: newBytes, encoding: .utf8) ?? ""
                let packetCount = packetStr.components(separatedBy: expectedSinglePacket).count - 1
                XCTAssertLessThanOrEqual(packetCount, TerminalTouchScrollDecision.maxLinesPerGestureCallback, "Per-tick emissions must be bounded")
                totalWheelEvents += packetCount
            }
        }

        XCTAssertFalse(view.isKineticScrolling)
        XCTAssertGreaterThan(totalWheelEvents, 0, "Alternate screen kinetic momentum must emit wheel events")
    }

    func testTakoTerminalViewKineticScrollDirectionReversalReciprocity() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        // DEC 1007 alternate scroll mode (arrow keys)
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertTrue(view.isAlternateScroll)

        // 1. Forward momentum (velocity +1500.0)
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1500.0))
        _ = view.perform(panSel, with: pan)

        delegate.inputDataReceived = Data()
        while view.isKineticScrolling {
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        }
        let forwardStr = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        let upArrowCount = forwardStr.components(separatedBy: "\u{1b}[A").count - 1

        // 2. Reverse momentum (velocity -1500.0)
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: -1500.0))
        _ = view.perform(panSel, with: pan)

        delegate.inputDataReceived = Data()
        while view.isKineticScrolling {
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        }
        let reverseStr = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        let downArrowCount = reverseStr.components(separatedBy: "\u{1b}[B").count - 1

        XCTAssertEqual(upArrowCount, downArrowCount, "Equal opposite swipe velocities must emit identical key counts")
        XCTAssertGreaterThan(upArrowCount, 0)
    }

    func testTakoTerminalViewKineticScrollBackgroundNotificationCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1500.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(view.isKineticScrolling, "App backgrounding must cancel kinetic momentum")
    }
}
#endif
