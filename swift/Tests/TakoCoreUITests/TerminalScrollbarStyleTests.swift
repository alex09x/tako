/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// The Mac's view: the iOS surface run (scripts/test-ios-surface.sh) leaves it out.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import XCTest
@testable import TakoCoreUI

/// The scrollbar is a thin Ember line on the right edge that widens while
/// it is hovered or dragged, and is not drawn when there is nothing to
/// scroll; the whole track width takes the press.
@MainActor
final class TerminalScrollbarStyleTests: XCTestCase {
    func testTheLineIsThinOnTheRightEdgeAndWidensWhenActive() {
        let resting = TerminalScrollbarStyle.knobFrame(y: 20, height: 50, active: false)
        let active = TerminalScrollbarStyle.knobFrame(y: 20, height: 50, active: true)
        XCTAssertEqual(resting.width, 3)
        XCTAssertEqual(active.width, 5)
        XCTAssertEqual(resting.maxX, TerminalScrollbarStyle.trackWidth - TerminalScrollbarStyle.rightInset)
        XCTAssertEqual(active.maxX, resting.maxX, "it grows inwards from the edge")
    }

    func testNothingToScrollDrawsNoLine() {
        let view = TakoTerminalNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.updateScroller()
        XCTAssertTrue(view.scrollbarKnob.isHidden)
        XCTAssertEqual(view.scrollbarLayer.backgroundColor?.alpha ?? 0, 0, "the track is not drawn")
    }

    func testWithNothingToScrollTheTrackTakesNoPress() {
        let view = TakoTerminalNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.updateScroller()
        let inTrack = CGPoint(x: view.scrollbarLayer.frame.midX, y: view.scrollbarLayer.frame.midY)
        XCTAssertFalse(view.scrollbarTakesPointer(at: inTrack), "the last columns are text when nothing scrolls")
        view.feed(data: Data((0..<200).map { "line \($0)\r\n" }.joined().utf8))
        view.updateScroller()
        XCTAssertTrue(view.scrollbarTakesPointer(at: inTrack))
    }

    func testAScrollingTerminalShowsTheLineAndItsSpanTakesThePress() {
        let view = TakoTerminalNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.feed(data: Data((0..<200).map { "line \($0)\r\n" }.joined().utf8))
        view.updateScroller()
        XCTAssertFalse(view.scrollbarKnob.isHidden)
        let knob = view.scrollbarKnob.frame
        XCTAssertEqual(knob.width, TerminalScrollbarStyle.restingWidth)
        // Anywhere across the track at the line's height grabs it.
        XCTAssertTrue(view.scrollbarKnobSpanContains(CGPoint(x: 0.5, y: knob.midY)))
        XCTAssertFalse(view.scrollbarKnobSpanContains(CGPoint(x: knob.midX, y: knob.maxY + 5)))

        view.isHoveringScrollbar = true
        view.updateScroller()
        XCTAssertEqual(view.scrollbarKnob.frame.width, TerminalScrollbarStyle.activeWidth)
    }
}
#endif
