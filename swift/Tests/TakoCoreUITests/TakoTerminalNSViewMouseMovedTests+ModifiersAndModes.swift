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
extension TakoTerminalNSViewMouseMovedTests {

    /// Movement outside the view bounds clamps the resolved cell to the grid edge,
    /// emits the clamped SGR coordinate report, and suppresses forwarding to next responder.
    func testMouseMoved_outsideGrid_clampsCoordinatesAndSuppressesForwarding() {
        MainActor.assumeIsolated {
            let spy = MouseMovedSpyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: TerminalTheme(windowPadding: 0))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate
            spy.addSubview(view)

            view.feed(data: Data("\u{1b}[?1003h\u{1b}[?1006h".utf8))

            // Subcase 1: Negative coordinates outside the view
            let negEvent = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: -50, y: -50),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 3001,
                clickCount: 0,
                pressure: 0.0
            )!

            view.mouseMoved(with: negEvent)

            let negReports = parseSGRReports(delegate.inputDataReceived)
            XCTAssertEqual(negReports.count, 1)
            guard negReports.count == 1 else { return }
            // Clamped: col clamped to 0 (1-based: 1), row clamped to rows-1 (23, 1-based: 24)
            XCTAssertEqual(negReports[0], "\u{1b}[<35;1;24M")
            XCTAssertEqual(spy.receivedEvents.count, 0)

            // Reset buffers
            delegate.inputDataReceived = Data()
            spy.receivedEvents.removeAll()

            // Subcase 2: Far beyond view bounds
            let beyondEvent = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 2000, y: 2000),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 3002,
                clickCount: 0,
                pressure: 0.0
            )!

            view.mouseMoved(with: beyondEvent)

            let beyondReports = parseSGRReports(delegate.inputDataReceived)
            XCTAssertEqual(beyondReports.count, 1)
            guard beyondReports.count == 1 else { return }
            // Clamped: col clamped to cols-1 (79, 1-based: 80), row clamped to 0 (1-based: 1)
            XCTAssertEqual(beyondReports[0], "\u{1b}[<35;80;1M")
            XCTAssertEqual(spy.receivedEvents.count, 0)
        }
    }

    /// Movement with modifier flags held encodes the modifier bits into the SGR button value:
    /// shift (+4), alt/option (+8), ctrl (+16), motion (+32), base button none (+3).
    /// In all cases, forwarding to the next responder is suppressed.
    func testMouseMoved_withModifierFlagsHeld_encodesModifiersAndSuppressesForwarding() {
        MainActor.assumeIsolated {
            let spy = MouseMovedSpyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: TerminalTheme(windowPadding: 0))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate
            spy.addSubview(view)

            view.feed(data: Data("\u{1b}[?1003h\u{1b}[?1006h".utf8))

            // Test cases: (name, modifierFlags, expectedButtonCode, eventNumber)
            // base = 3 + 32 = 35
            let cases: [(String, NSEvent.ModifierFlags, Int, Int)] = [
                ("shift", .shift, 35 + 4, 4001),
                ("option", .option, 35 + 8, 4002),
                ("control", .control, 35 + 16, 4003),
                ("shift+control", [.shift, .control], 35 + 4 + 16, 4004),
                ("shift+option+control", [.shift, .option, .control], 35 + 4 + 8 + 16, 4005),
            ]

            for (label, flags, expectedButtonCode, evNum) in cases {
                delegate.inputDataReceived = Data()
                spy.receivedEvents.removeAll()

                let event = NSEvent.mouseEvent(
                    with: .mouseMoved,
                    location: NSPoint(x: 50, y: 550),
                    modifierFlags: flags,
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: evNum,
                    clickCount: 0,
                    pressure: 0.0
                )!

                view.mouseMoved(with: event)

                XCTAssertFalse(delegate.inputDataReceived.isEmpty, "Failed for modifier: \(label)")
                let reports = parseSGRReports(delegate.inputDataReceived)
                XCTAssertEqual(reports.count, 1, "Expected exactly 1 report for modifier: \(label)")
                guard reports.count == 1 else { continue }
                XCTAssertEqual(reports[0], "\u{1b}[<\(expectedButtonCode);7;4M", "Incorrect code for modifier: \(label)")

                XCTAssertEqual(spy.receivedEvents.count, 0, "Expected 0 spy events for modifier: \(label)")
            }
        }
    }

    // MARK: - (e) Mode Transitions: Entering and Leaving Reporting Mode

    /// Verifies behavior immediately across mode transitions:
    /// 1. Initially reporting OFF -> 0 bytes to delegate, forwarded to next responder.
    /// 2. Immediately after entering reporting mode (?1003h?1006h) -> exactly 1 report to delegate, forwarding suppressed.
    /// 3. Immediately after leaving reporting mode (?1003l?1006l) -> 0 bytes to delegate, forwarded to next responder.
    func testMouseMoved_modeTransitions_enteringAndLeavingReportingMode() {
        MainActor.assumeIsolated {
            let spy = MouseMovedSpyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: TerminalTheme(windowPadding: 0))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate
            spy.addSubview(view)

            // --- Phase 1: Reporting OFF ---
            let eventOff = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 50, y: 550),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 5001,
                clickCount: 0,
                pressure: 0.0
            )!

            view.mouseMoved(with: eventOff)

            XCTAssertTrue(delegate.inputDataReceived.isEmpty)
            XCTAssertEqual(delegate.inputDataReceived.count, 0)
            XCTAssertEqual(spy.receivedEvents.count, 1)
            guard spy.receivedEvents.count == 1 else { return }
            XCTAssertTrue(spy.receivedEvents[0] === eventOff)
            XCTAssertEqual(spy.receivedEvents[0].eventNumber, 5001)

            // --- Phase 2: Enter Reporting Mode (?1003h?1006h) ---
            view.feed(data: Data("\u{1b}[?1003h\u{1b}[?1006h".utf8))
            delegate.inputDataReceived = Data()
            spy.receivedEvents.removeAll()

            let eventOn = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 50, y: 550),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 5002,
                clickCount: 0,
                pressure: 0.0
            )!

            view.mouseMoved(with: eventOn)

            XCTAssertFalse(delegate.inputDataReceived.isEmpty)
            let onReports = parseSGRReports(delegate.inputDataReceived)
            XCTAssertEqual(onReports.count, 1)
            guard onReports.count == 1 else { return }
            XCTAssertEqual(onReports[0], "\u{1b}[<35;7;4M")
            XCTAssertEqual(spy.receivedEvents.count, 0)

            // --- Phase 3: Leave Reporting Mode (?1003l?1006l) ---
            view.feed(data: Data("\u{1b}[?1003l\u{1b}[?1006l".utf8))
            delegate.inputDataReceived = Data()
            spy.receivedEvents.removeAll()

            let eventDisabled = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 50, y: 550),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 5003,
                clickCount: 0,
                pressure: 0.0
            )!

            view.mouseMoved(with: eventDisabled)

            XCTAssertTrue(delegate.inputDataReceived.isEmpty)
            XCTAssertEqual(delegate.inputDataReceived.count, 0)
            XCTAssertEqual(spy.receivedEvents.count, 1)
            guard spy.receivedEvents.count == 1 else { return }
            XCTAssertTrue(spy.receivedEvents[0] === eventDisabled)
            XCTAssertEqual(spy.receivedEvents[0].eventNumber, 5003)
        }
    }
}
#endif
