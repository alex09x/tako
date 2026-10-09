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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@MainActor
extension TakoTerminalNSViewScrollTests {
    func testMouseOwnedWheelBatchesNormalStepsInOrderAndCapsBurst() throws {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1006h\u{1b}[?1000h".utf8))
        let baseline = delegate.inputDataReceived.count

        let normalEvent = try XCTUnwrap(scrollEvent(deltaY: 3, precise: false))
        let cell = view.cellAt(view.convert(normalEvent.locationInWindow, from: nil))
        let up = view.mouseReportBytes(button: .wheelUp, action: .press, cell: cell, event: normalEvent)
        view.scrollWheel(with: normalEvent)
        XCTAssertEqual(delegate.inputDataReceived.dropFirst(baseline), up + up + up)

        let afterNormal = delegate.inputDataReceived.count
        let burstEvent = try XCTUnwrap(scrollEvent(deltaY: -99, precise: false))
        let burstCell = view.cellAt(view.convert(burstEvent.locationInWindow, from: nil))
        let down = view.mouseReportBytes(button: .wheelDown, action: .press, cell: burstCell, event: burstEvent)
        var expectedBurst = Data()
        for _ in 0..<TerminalTouchScrollDecision.maxLinesPerGestureCallback { expectedBurst.append(down) }
        view.scrollWheel(with: burstEvent)
        XCTAssertEqual(delegate.inputDataReceived.dropFirst(afterNormal), expectedBurst)
    }

    func testAlternateScreenDEC1007SendsCursorKeysButPrimaryScreenStaysLocal() throws {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h\u{1b}[?1h".utf8))
        let baseline = delegate.inputDataReceived.count

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 2, precise: false)))
        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: -1, precise: false)))
        XCTAssertEqual(delegate.inputDataReceived.dropFirst(baseline), Data("\u{1b}OA\u{1b}OA\u{1b}OB".utf8))

        view.feed(data: Data("\u{1b}[?1007l".utf8))
        let reportsBeforeModeReset = delegate.inputDataReceived.count
        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: false)))
        XCTAssertEqual(delegate.inputDataReceived.count, reportsBeforeModeReset,
                       "alternate screen without DEC 1007 must not synthesize cursor keys")

        view.feed(data: Data("\u{1b}[?1049l".utf8))
        let reportsBeforePrimary = delegate.inputDataReceived.count
        let visibleBeforePrimary = topVisibleLine(view)
        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: false)))
        XCTAssertEqual(delegate.inputDataReceived.count, reportsBeforePrimary)
        XCTAssertNotEqual(topVisibleLine(view), visibleBeforePrimary)
    }

    func testAlternateScreenDEC1007UsesNormalCursorKeyEncoding() throws {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h".utf8))
        let baseline = delegate.inputDataReceived.count

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: false)))
        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: -1, precise: false)))

        XCTAssertEqual(delegate.inputDataReceived.dropFirst(baseline), Data("\u{1b}[A\u{1b}[B".utf8))
    }

    func testMouseReportingTakesPrecedenceOverDEC1007ArrowEncoding() throws {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let baseline = delegate.inputDataReceived.count
        let event = try XCTUnwrap(scrollEvent(deltaY: 1, precise: false))
        let cell = view.cellAt(view.convert(event.locationInWindow, from: nil))
        let expected = view.mouseReportBytes(button: .wheelUp, action: .press, cell: cell, event: event)

        view.scrollWheel(with: event)

        XCTAssertEqual(delegate.inputDataReceived.dropFirst(baseline), expected)
    }


    func testEmptyScrollbackScrollbarClickAndDragSendsNoInput() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate

        XCTAssertEqual(view.scrollbackLength, 0)
        let baseline = delegate.inputDataReceived.count

        let clickPoint = NSPoint(x: 595, y: 150)
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: downEvent)
        XCTAssertEqual(delegate.inputDataReceived.count, baseline, "mouseDown on empty scrollbar track must not synthesize input")

        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 595, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDragged(with: dragEvent)
        XCTAssertEqual(delegate.inputDataReceived.count, baseline, "mouseDragged on empty scrollbar track must not synthesize input")

        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 595, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )!
        view.mouseUp(with: upEvent)
        XCTAssertEqual(delegate.inputDataReceived.count, baseline, "mouseUp on empty scrollbar track must not synthesize input")
    }

    func testAlternateScreenDEC1007ScrollbarClickAndDragSynthesizesKeys() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h".utf8))
        let baseline = delegate.inputDataReceived.count

        let clickPoint = NSPoint(x: 595, y: 250)
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: clickPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: downEvent)
        XCTAssertGreaterThan(delegate.inputDataReceived.count, baseline, "mouseDown in DEC 1007 alternate screen must synthesize PageUp")

        let dragBaseline = delegate.inputDataReceived.count
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 595, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDragged(with: dragEvent)
        XCTAssertGreaterThan(delegate.inputDataReceived.count, dragBaseline, "mouseDragged in DEC 1007 alternate screen must synthesize arrow keys")
    }

}
#endif
