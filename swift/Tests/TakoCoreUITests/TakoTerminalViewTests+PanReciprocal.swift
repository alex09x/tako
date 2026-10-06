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
    func testTakoTerminalViewPanGestureReciprocalLifecycleInDEC1007AlternateScrollMode() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        // Enter alternate screen with DEC1007 alternate scroll enabled
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertTrue(view.isAlternateScroll)

        // Forward gesture: 3 steps of +1.0 * cellH
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        for _ in 0..<3 {
            pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
            _ = view.perform(panSel, with: pan)
        }
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[A\u{1b}[A\u{1b}[A")

        // Reciprocal gesture: 3 steps of -1.0 * cellH
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        for _ in 0..<3 {
            pan.setTranslation(CGPoint(x: 0, y: -cellH), in: view)
            _ = view.perform(panSel, with: pan)
        }
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[B\u{1b}[B\u{1b}[B")
    }

    func testTakoTerminalViewPanGestureReciprocalLifecycleInPrimaryScreenLocalScrollback() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        // Feed scrollback lines
        let history = (1...60).map { "Scrollback row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.viewportOffset, 0)

        // Forward gesture (swipe down -> scroll up into history): 5 steps of 1.0 * cellH
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        for _ in 0..<5 {
            pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
            _ = view.perform(panSel, with: pan)
        }
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(view.viewportOffset, 5, "Forward gesture must move viewport 5 lines into scrollback")
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Local scrollback must not emit PTY bytes")

        // Reciprocal gesture (swipe up -> scroll down back to tail): 5 steps of -1.0 * cellH
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        for _ in 0..<5 {
            pan.setTranslation(CGPoint(x: 0, y: -cellH), in: view)
            _ = view.perform(panSel, with: pan)
        }
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(view.viewportOffset, 0, "Reciprocal gesture must restore viewport back to live tail (offset 0)")
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    func testTakoTerminalViewPanGestureMidGestureDirectionReversal() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        pan.setMockLocation(CGPoint(x: cellW * 10.0, y: cellH * 5.0)) // col 10 -> 11, row 5 -> 6

        // Single gesture that reverses direction mid-drag
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed

        // 1. Move down +2.5 lines -> emits 2 WheelUp, residual +0.5
        pan.setTranslation(CGPoint(x: 0, y: cellH * 2.5), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;11;6M\u{1b}[<64;11;6M")

        // 2. Reverse up -3.0 lines -> accum = 0.5 - 3.0 = -2.5 -> emits 2 WheelDown, residual -0.5
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 3.0), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;11;6M\u{1b}[<64;11;6M\u{1b}[<65;11;6M\u{1b}[<65;11;6M")

        // 3. Move down +1.5 lines -> accum = -0.5 + 1.5 = +1.0 -> emits 1 WheelUp, residual 0.0
        pan.setTranslation(CGPoint(x: 0, y: cellH * 1.5), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;11;6M\u{1b}[<64;11;6M\u{1b}[<65;11;6M\u{1b}[<65;11;6M\u{1b}[<64;11;6M")

        pan.state = .ended
        _ = view.perform(panSel, with: pan)
    }

    func testTakoTerminalViewPanGestureFloodCapClampingSymmetry() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        pan.setMockLocation(CGPoint(x: cellW * 2.0, y: cellH * 2.0)) // col 2 -> 3, row 2 -> 3

        let maxCap = TerminalTouchScrollDecision.maxLinesPerGestureCallback
        XCTAssertEqual(maxCap, 10)

        // Single frame huge jump +30 lines
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 30), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let expectedUpData = String(repeating: "\u{1b}[<64;3;3M", count: maxCap)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), expectedUpData)

        // Single frame huge jump -30 lines
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 30), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let expectedDownData = String(repeating: "\u{1b}[<65;3;3M", count: maxCap)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), expectedDownData)
    }


}
#endif
