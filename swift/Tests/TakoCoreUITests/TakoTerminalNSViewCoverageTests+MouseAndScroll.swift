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
import Carbon
import XCTest
@testable import TakoCoreUI

extension TakoTerminalNSViewCoverageTests {

    func testMouseReportBytesClampingAndModifiers() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("\u{1b}[?1003h\u{1b}[?1006h".utf8))
        let negativeBytes = view.mouseReportBytes(button: .left, action: .press, cell: (-5, -10))
        XCTAssertFalse(negativeBytes.isEmpty)

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [.shift, .option, .control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        let modifiedBytes = view.mouseReportBytes(button: .left, action: .motion, cell: (5, 5), event: event)
        XCTAssertFalse(modifiedBytes.isEmpty)
    }

    func testMouseClickSelectionModes() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("hello world this is a test line\r\n".utf8))

        let p = view.cellOrigin(row: 0, col: 2)
        let singleOpt = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: p.x + 2, y: p.y + 2),
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: singleOpt)
        XCTAssertEqual(view.core.selectionRange()?.mode, .rectangular)

        let tripleClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: p.x + 2, y: p.y + 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 3,
            pressure: 1.0
        )!
        view.mouseDown(with: tripleClick)
        XCTAssertTrue(view.core.selectedText()?.contains("hello world") == true)

        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: p.x + 50, y: p.y + 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 3,
            pressure: 1.0
        )!
        view.mouseDragged(with: drag)

        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: p.x + 2, y: p.y + 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )!
        let singleClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: p.x + 2, y: p.y + 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: singleClick)
        view.mouseUp(with: up)
        XCTAssertNil(view.core.selectedText())
    }

    func testRightAndOtherMouseEvents() {
        let (view, _) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}[?1003h\u{1b}[?1006h".utf8))

        let rightDown = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.rightMouseDown(with: rightDown)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let rightUp = NSEvent.mouseEvent(
            with: .rightMouseUp,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )!
        view.rightMouseUp(with: rightUp)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let otherDown = NSEvent.mouseEvent(
            with: .otherMouseDown,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.otherMouseDown(with: otherDown)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let otherUp = NSEvent.mouseEvent(
            with: .otherMouseUp,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )!
        view.otherMouseUp(with: otherUp)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let moved = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0.0
        )!
        view.mouseMoved(with: moved)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertNotNil(view.mouseCell)

        view.mouseEntered(with: moved)
        view.mouseExited(with: moved)
        XCTAssertNil(view.mouseCell)
    }

    // MARK: - 11. Scroll Wheel in All Modes

    private func makeScrollEvent(deltaY: Int32, precise: Bool, phase: NSEvent.Phase = []) -> NSEvent? {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 1,
            wheel1: deltaY, wheel2: 0, wheel3: 0
        ) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    func testScrollWheelAlternateScreenAlternateScroll() throws {
        let (view, _) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertTrue(view.isAlternateScroll)

        let scrollUpPrecise = try XCTUnwrap(makeScrollEvent(deltaY: 9, precise: true))
        view.scrollWheel(with: scrollUpPrecise)
        let upStr = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(upStr.contains("\u{1b}[A") || upStr.contains("\u{1b}OA"))
        delegate.inputDataReceived.removeAll()

        let scrollDownNotched = try XCTUnwrap(makeScrollEvent(deltaY: -2, precise: false))
        view.scrollWheel(with: scrollDownNotched)
        let downStr = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(downStr.contains("\u{1b}[B") || downStr.contains("\u{1b}OB"))
    }

    func testScrollWheelReportingModeWheelUpAndDown() throws {
        let (view, _) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        delegate.inputDataReceived.removeAll()

        let scrollUp = try XCTUnwrap(makeScrollEvent(deltaY: 6, precise: true))
        view.scrollWheel(with: scrollUp)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let scrollDown = try XCTUnwrap(makeScrollEvent(deltaY: -6, precise: true))
        view.scrollWheel(with: scrollDown)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
    }

    func testScrollWheelLocalBoundarySettlement() throws {
        let (view, _) = makeHostedView()
        let lines = (0..<30).map { "Line \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(lines.utf8))

        let scrollUp = try XCTUnwrap(makeScrollEvent(deltaY: 10, precise: false))
        view.scrollWheel(with: scrollUp)
        XCTAssertGreaterThan(view.viewportOffset, 0)

        let scrollDown = try XCTUnwrap(makeScrollEvent(deltaY: -20, precise: false))
        view.scrollWheel(with: scrollDown)
        XCTAssertEqual(view.viewportOffset, 0)
    }

    // MARK: - 12. Copy, Paste, Select All

}
