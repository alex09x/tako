import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// `mouse-shift-capture` and XTSHIFTESCAPE: whether a Shift-held click goes
/// to a program that reports the mouse or selects text. false and true are
/// defaults the program can override; always and never are not.
@MainActor
final class TakoTerminalNSViewMouseShiftCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TakoTerminalNSView.isMetalDisabledForTesting = true
    }

    /// A view running a program that reports the mouse (SGR), after it sent
    /// `request` (e.g. XTSHIFTESCAPE).
    private func reportingView(_ capture: MouseShiftCapture, request: String = "") -> (TakoTerminalNSView, MockTerminalNSViewDelegate) {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.layoutSubtreeIfNeeded()
        view.feed(data: Data("hello world\u{1b}[?1000h\u{1b}[?1006h\(request)".utf8))
        view.mouseShiftCapture = capture
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        return (view, delegate)
    }

    private func shiftClick(_ view: TakoTerminalNSView) {
        let origin = view.cellOrigin(row: 0, col: 0)
        let location = NSPoint(x: origin.x + max(view.cellWidth, 1) / 2, y: origin.y + max(view.cellHeight, 1) / 2)
        view.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [.shift],
            timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!)
    }

    /// Whether the program saw the click: an SGR report starts ESC [ <.
    private func programSawIt(_ delegate: MockTerminalNSViewDelegate) -> Bool {
        String(decoding: delegate.inputDataReceived, as: UTF8.self).contains("\u{1b}[<")
    }

    func testTheRuleForEveryValueAndRequest() {
        XCTAssertEqual(
            [MouseShiftCapture.off, .on, .always, .never].map { capture in
                [nil, false, true].map { capture.capturesShift(programRequest: $0) }
            },
            [
                [false, false, true],  // false: selects unless the program asks
                [true, false, true],   // true: the program's unless it gives it back
                [true, true, true],    // always
                [false, false, false], // never
            ]
        )
    }

    func testFalseSelectsWithShift() {
        let (view, delegate) = reportingView(.off)
        shiftClick(view)
        XCTAssertFalse(programSawIt(delegate))
    }

    func testFalseGivesShiftToAProgramThatAsks() {
        let (view, delegate) = reportingView(.off, request: "\u{1b}[>1s")
        shiftClick(view)
        XCTAssertTrue(programSawIt(delegate))
    }

    func testTrueGivesShiftToTheProgram() {
        let (view, delegate) = reportingView(.on)
        shiftClick(view)
        XCTAssertTrue(programSawIt(delegate))
    }

    func testTrueTakesShiftBackWhenTheProgramDeclines() {
        let (view, delegate) = reportingView(.on, request: "\u{1b}[>0s")
        shiftClick(view)
        XCTAssertFalse(programSawIt(delegate))
    }

    func testAlwaysIgnoresAProgramThatDeclines() {
        let (view, delegate) = reportingView(.always, request: "\u{1b}[>0s")
        shiftClick(view)
        XCTAssertTrue(programSawIt(delegate))
    }

    func testNeverIgnoresAProgramThatAsks() {
        let (view, delegate) = reportingView(.never, request: "\u{1b}[>1s")
        shiftClick(view)
        XCTAssertFalse(programSawIt(delegate))
    }

    func testDefaultIsFalse() {
        XCTAssertEqual(TakoTerminalNSView(frame: .zero).mouseShiftCapture, .off)
    }
}
#endif
