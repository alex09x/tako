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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Local spy superview that observes forwarding along the AppKit responder chain.
///
/// An NSView forwards an unhandled mouseMoved event to its next responder, which is its
/// superview when installed in a view hierarchy. This spy records each NSEvent it receives
/// so tests can verify the real super.mouseMoved routing path without relying on method stubs.
@MainActor
final class MouseMovedSpyView: NSView {
    var receivedEvents: [NSEvent] = []

    override func mouseMoved(with event: NSEvent) {
        receivedEvents.append(event)
        super.mouseMoved(with: event)
    }
}

/// Tests for TakoTerminalNSView.mouseMoved(with:) event routing.
///
/// The expected reports name cells counted from the view's corner, so these
/// views have no padding; where the grid sits is TerminalGridLayoutTests'.
///
/// Verifies that mouseMoved dispatches report bytes to the delegate when mouse reporting
/// is enabled and suppresses forwarding to super.mouseMoved when the motion is consumed,
/// while preserving forwarding to the responder chain when reporting is disabled or no
/// report bytes are generated (matching mouseDown, mouseUp, and other mouse event handlers).
final class TakoTerminalNSViewMouseMovedTests: XCTestCase {

    /// Helper to split concatenated SGR mouse report byte sequences.
    /// Each SGR report sequence begins with ESC [ < and terminates with M or m.
    func parseSGRReports(_ data: Data) -> [String] {
        guard let str = String(data: data, encoding: .utf8), !str.isEmpty else { return [] }
        var reports: [String] = []
        let components = str.components(separatedBy: "\u{1b}")
        for comp in components where !comp.isEmpty {
            reports.append("\u{1b}" + comp)
        }
        return reports
    }

    // MARK: - (a) Mouse Reporting OFF

    /// With mouse reporting OFF, synthesized mouseMoved delivers no input data to the
    /// delegate and is forwarded to the next responder (spy superview).
    func testMouseMoved_whenReportingOff_deliversNoInputToDelegate_andForwardsToNextResponder() {
        MainActor.assumeIsolated {
            let spy = MouseMovedSpyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: TerminalTheme(windowPadding: 0))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate
            spy.addSubview(view)

            let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 50, y: 550),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1001,
                clickCount: 0,
                pressure: 0.0
            )!

            view.mouseMoved(with: event)

            // Delegate must receive no data
            XCTAssertTrue(delegate.inputDataReceived.isEmpty)
            XCTAssertEqual(delegate.inputDataReceived.count, 0)

            // Spy superview must receive exactly one forwarded event
            XCTAssertEqual(spy.receivedEvents.count, 1)
            guard spy.receivedEvents.count == 1 else { return }
            XCTAssertTrue(spy.receivedEvents[0] === event)
            XCTAssertEqual(spy.receivedEvents[0].eventNumber, 1001)
        }
    }

    // MARK: - (b) Mouse Reporting ON (SGR)

    /// With mouse reporting ON (SGR), synthesized mouseMoved delivers exactly one report to the
    /// delegate and suppresses forwarding to the next responder.
    func testMouseMoved_whenReportingOnSGR_deliversExactlyOneReport_andSuppressesForwardingToNextResponder() {
        MainActor.assumeIsolated {
            let spy = MouseMovedSpyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: TerminalTheme(windowPadding: 0))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate
            spy.addSubview(view)

            // Enable SGR Any-Event mouse reporting:
            // ?1003h enables AnyEvent tracking (motion without buttons pressed).
            // ?1006h enables SGR extended coordinate format.
            view.feed(data: Data("\u{1b}[?1003h\u{1b}[?1006h".utf8))

            let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 50, y: 550),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1002,
                clickCount: 0,
                pressure: 0.0
            )!

            view.mouseMoved(with: event)

            // Assert delegate received bytes are non-empty
            XCTAssertFalse(delegate.inputDataReceived.isEmpty)

            // Assert exact count: exactly one SGR report delivered to delegate
            let reports = parseSGRReports(delegate.inputDataReceived)
            XCTAssertEqual(reports.count, 1)
            guard reports.count == 1 else { return }
            // Cell (col 6, row 3) 0-based -> 1-based col 7, row 4. Button code: 3 (none) + 32 (motion) = 35.
            XCTAssertEqual(reports[0], "\u{1b}[<35;7;4M")

            // Assert spy superview received zero events because motion was consumed
            XCTAssertEqual(spy.receivedEvents.count, 0)
        }
    }

    /// Characterizes DECSET 1000 Normal Tracking mode with mouseMoved.
    ///
    /// When only DECSET 1000 is enabled (\u{1b}[?1000h\u{1b}[?1006h as in testMouseReportingWhenEnabled),
    /// the terminal core suppresses motion events when no buttons are pressed (action == Motion with
    /// MouseTracking::Normal returns empty data). Consequently, delegate receives no data while
    /// the event is still forwarded to next responder.
    func testMouseMoved_withNormalTracking1000h_suppressesMotionReporting_andStillForwards() {
        MainActor.assumeIsolated {
            let spy = MouseMovedSpyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: TerminalTheme(windowPadding: 0))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate
            spy.addSubview(view)

            view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))

            let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 50, y: 550),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1003,
                clickCount: 0,
                pressure: 0.0
            )!

            view.mouseMoved(with: event)

            XCTAssertTrue(delegate.inputDataReceived.isEmpty)
            XCTAssertEqual(delegate.inputDataReceived.count, 0)
            XCTAssertEqual(spy.receivedEvents.count, 1)
            guard spy.receivedEvents.count == 1 else { return }
            XCTAssertTrue(spy.receivedEvents[0] === event)
            XCTAssertEqual(spy.receivedEvents[0].eventNumber, 1003)
        }
    }

    // MARK: - (c) NSEvent Object Identity

    /// Proves by event identity (===) and unique eventNumber that the NSEvent object received
    /// by the next responder is identical to the one passed to mouseMoved(with:).
    func testMouseMoved_eventIdentityForwardedToNextResponder() {
        MainActor.assumeIsolated {
            let spy = MouseMovedSpyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: TerminalTheme(windowPadding: 0))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate
            spy.addSubview(view)

            let event1 = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 100, y: 500),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 2001,
                clickCount: 0,
                pressure: 0.0
            )!

            let event2 = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 200, y: 400),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 2002,
                clickCount: 0,
                pressure: 0.0
            )!

            view.mouseMoved(with: event1)
            view.mouseMoved(with: event2)

            XCTAssertEqual(spy.receivedEvents.count, 2)
            guard spy.receivedEvents.count == 2 else { return }

            // Exact object identity check using === operator
            XCTAssertTrue(spy.receivedEvents[0] === event1)
            XCTAssertTrue(spy.receivedEvents[1] === event2)
            XCTAssertFalse(spy.receivedEvents[0] === event2)

            // Event number matching check
            XCTAssertEqual(spy.receivedEvents[0].eventNumber, 2001)
            XCTAssertEqual(spy.receivedEvents[1].eventNumber, 2002)
        }
    }

    // MARK: - (d) Movement Outside Grid and Movement with Modifiers

}
