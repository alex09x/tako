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
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        // Feed background history on primary screen
        let history = (1...30).map { "History line \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.viewportOffset, 0)

        // Claude Code mode sequence on primary screen:
        // Hide cursor (?25l), Normal tracking (?1000h), ButtonEvent tracking (?1002h), SGR format (?1006h), Bracketed paste (?2004h)
        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        XCTAssertFalse(view.isAlternateScreen, "Claude Code operates on primary screen")
        XCTAssertEqual(view.core.modes().mouseTracking, .buttonEvent)
        XCTAssertTrue(view.core.modes().mouseSgr)

        // 1. Swiping down (panning down, translation.y > 0) -> direction .up -> sends SGR wheel up (\e[<64;...M)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 2), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let inputUpString = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(inputUpString.contains("\u{1b}[<64;"), "Primary screen with Claude mouse tracking must send SGR WheelUp: \(inputUpString)")
        XCTAssertEqual(view.viewportOffset, 0, "Local viewport must not move when mouse tracking is active")

        // 2. Swiping up (panning up, translation.y < 0) -> direction .down -> sends SGR wheel down (\e[<65;...M)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: -cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let inputDownString = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(inputDownString.contains("\u{1b}[<65;"), "Primary screen with Claude mouse tracking must send SGR WheelDown: \(inputDownString)")
        XCTAssertEqual(view.viewportOffset, 0)

        // 3. Claude exits and restores normal terminal state
        view.feed(data: Data("\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h".utf8))
        XCTAssertEqual(view.core.modes().mouseTracking, .off)

        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 3), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "After Claude exits, pan must not send input to PTY")
        XCTAssertGreaterThan(view.viewportOffset, 0, "After Claude exits, pan must scroll local scrollback")
    }

    func testTakoTerminalViewPanGestureIgnoredDuringActiveSelection() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let longPressSel = Selector(("handleLongPress:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        // Feed some text
        view.feed(data: Data("First row of text for selection test\r\nSecond row\r\n".utf8))

        // Start long-press selection
        let longPress = MockLongPressGestureRecognizer()
        // Begin selection at (row 0, col 0)
        longPress.state = .began
        _ = view.perform(longPressSel, with: longPress)

        XCTAssertTrue(view.core.hasSelection(), "Long press begins selection")

        // While selection is active, pan gesture should be ignored
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: view.renderer.metrics.cellHeight * 3), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(view.viewportOffset, 0, "Pan during selection must not scroll viewport")
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Pan during selection must not send input data")
    }

    func testTakoTerminalViewPanGestureReciprocalLifecycleInClaudeMouseTrackingMode() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        // Claude Code mode sequence on primary screen:
        // Hide cursor (?25l), Normal (?1000h), ButtonEvent (?1002h), SGR (?1006h), Bracketed paste (?2004h)
        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.core.modes().mouseTracking, .buttonEvent)
        XCTAssertTrue(view.core.modes().mouseSgr)

        // Set touch point at col 14, row 7 (SGR: 1-based col 15, row 8)
        pan.setMockLocation(CGPoint(x: cellW * 14.5, y: cellH * 7.5))

        // Phase 1: Forward Gesture (Native swipe down -> translation.y > 0 -> WheelUp into history)
        // 4 steps of 0.75 * cellH each (total distance = 3.0 * cellH)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)

        // Step 1: translation +0.75 * cellH -> accum = 0.75, lines = 0 -> 0 events
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Step 1 (0.75 lines) must not emit before full line threshold")

        // Step 2: translation +0.75 * cellH -> accum = 1.5, lines = 1 -> 1 WheelUp emitted, residual = 0.5
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;15;8M")

        // Step 3: translation +0.75 * cellH -> accum = 1.25, lines = 1 -> 2nd WheelUp emitted, residual = 0.25
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;15;8M\u{1b}[<64;15;8M")

        // Step 4: translation +0.75 * cellH -> accum = 1.0, lines = 1 -> 3rd WheelUp emitted, residual = 0.0
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;15;8M\u{1b}[<64;15;8M\u{1b}[<64;15;8M")

        // End forward gesture
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let forwardEvents = delegate.inputDataReceived

        // Phase 2: Reciprocal Gesture (Native swipe up -> translation.y < 0 -> WheelDown toward tail)
        // 4 steps of -0.75 * cellH each (total distance = -3.0 * cellH)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)

        // Step 1: translation -0.75 * cellH -> accum = -0.75, lines = 0 -> 0 events
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Reciprocal Step 1 (-0.75 lines) must not emit before full line threshold")

        // Step 2: translation -0.75 * cellH -> accum = -1.5, lines = 1 -> 1 WheelDown emitted, residual = -0.5
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<65;15;8M")

        // Step 3: translation -0.75 * cellH -> accum = -1.25, lines = 1 -> 2nd WheelDown emitted, residual = -0.25
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<65;15;8M\u{1b}[<65;15;8M")

        // Step 4: translation -0.75 * cellH -> accum = -1.0, lines = 1 -> 3rd WheelDown emitted, residual = 0.0
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<65;15;8M\u{1b}[<65;15;8M\u{1b}[<65;15;8M")

        // End reciprocal gesture
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let reciprocalEvents = delegate.inputDataReceived

        // Strict Reciprocal Verification:
        // 1. Equal event count and payload size
        XCTAssertEqual(forwardEvents.count, reciprocalEvents.count, "Reciprocal gesture sequences must have identical total byte length")
        XCTAssertEqual(forwardEvents.count, 3 * "\u{1b}[<64;15;8M".utf8.count)

        // 2. Exact coordinates and button mapping
        let forwardStr = String(data: forwardEvents, encoding: .utf8) ?? ""
        let reciprocalStr = String(data: reciprocalEvents, encoding: .utf8) ?? ""
        XCTAssertEqual(forwardStr, "\u{1b}[<64;15;8M\u{1b}[<64;15;8M\u{1b}[<64;15;8M")
        XCTAssertEqual(reciprocalStr, "\u{1b}[<65;15;8M\u{1b}[<65;15;8M\u{1b}[<65;15;8M")
        XCTAssertEqual(view.viewportOffset, 0, "Local viewport offset must remain 0 during mouse-tracking pan routing")
    }

    func testTakoTerminalViewPanGestureReciprocalLifecycleWithSubLineResidualAtEnd() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        // Enable Claude mouse tracking mode
        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        pan.setMockLocation(CGPoint(x: cellW * 5.0, y: cellH * 3.0)) // col 5 -> 6, row 3 -> 4

        // Forward gesture: 4 steps of +0.7 * cellH (total +2.8 * cellH, leaving +0.8 residual at end)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed

        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = 0.7 -> 0 lines
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = 1.4 -> 1 line, residual 0.4
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = 1.1 -> 1 line, residual 0.1
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = 0.8 -> 0 lines, residual 0.8

        pan.state = .ended
        _ = view.perform(panSel, with: pan) // resets accum to 0

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;6;4M\u{1b}[<64;6;4M")

        // Reciprocal gesture: 4 steps of -0.7 * cellH (total -2.8 * cellH, leaving -0.8 residual at end)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed

        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = -0.7 -> 0 lines
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = -1.4 -> 1 line, residual -0.4
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = -1.1 -> 1 line, residual -0.1
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = -0.8 -> 0 lines, residual -0.8

        pan.state = .ended
        _ = view.perform(panSel, with: pan) // resets accum to 0

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<65;6;4M\u{1b}[<65;6;4M")

        // Verify clean isolation: next gesture starts fresh without residual leakage
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.5), in: view)
        _ = view.perform(panSel, with: pan) // accum = 0.5 -> 0 lines (would be 1.3 if residual 0.8 leaked)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Subsequent gesture must not inherit residual from ended gesture")
        pan.state = .ended
        _ = view.perform(panSel, with: pan)
    }


}
#endif
