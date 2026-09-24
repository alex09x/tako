import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// What a scroll gesture does to the viewport.
///
/// The surface used to round every event to a whole row on its own and throw
/// the remainder away, then promote any sub-threshold event back up to one
/// row. Slow trackpad motion therefore produced either nothing or a full row
/// and never the truth in between, which is what a jerk is.
@MainActor
final class TakoTerminalNSViewScrollTests: XCTestCase {
    /// Enough lines to have somewhere to scroll to.
    private func makeView(lines: Int = 200) -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let text = (0..<lines).map { "L\($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(text.utf8))
        return view
    }

    /// How many escape sequences the program has been sent.
    ///
    /// The mock accumulates raw bytes, so its `count` is a byte count -- one
    /// SGR wheel report is eleven of them. Counting introducers instead makes
    /// the assertion say what it means.
    private func reportCount(_ delegate: MockTerminalNSViewDelegate) -> Int {
        delegate.inputDataReceived.filter { $0 == 0x1b }.count
    }

    /// The first line currently visible, which is what moving by rows changes.
    private func topVisibleLine(_ view: TakoTerminalNSView) -> String {
        view.plainText(startRow: 0, maxRows: 1)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A scroll event of the given kind. `hasPreciseScrollingDeltas` cannot be
    /// set on NSEvent directly; it follows from the CGEvent's units.
    private func scrollEvent(deltaY: Int32, precise: Bool, phase: NSEvent.Phase = []) -> NSEvent? {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 1,
            wheel1: deltaY, wheel2: 0, wheel3: 0
        ) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    /// One point of three is a third of a row, and that is what is presented
    /// -- not nothing, and not a whole row.
    ///
    /// This used to assert that the top visible line was unchanged, which was
    /// a proxy for "no visible jump". It is no longer the right question: the
    /// engine is deliberately positioned a row further back and translated up
    /// into place, so the row index moves while the picture does not jump.
    /// `presentedScrollRows` is the number that was always meant, so it is
    /// asserted directly, exactly, instead.
    func testOnePointOfPreciseMotionPresentsExactlyOneThirdOfARow() throws {
        let view = makeView()
        XCTAssertEqual(view.presentedScrollRows, 0, accuracy: 1e-9)

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))

        XCTAssertEqual(view.presentedScrollRows, 1.0 / 3.0, accuracy: 1e-6,
                       "a third of a row of motion was not presented as a third of a row")
    }

    /// The fraction is carried, not discarded: three one-point events are one
    /// whole row, arrived at a third at a time, and the third one lands on an
    /// exact boundary with nothing left translating.
    func testPreciseDeltasAccumulateIntoExactlyOneRow() throws {
        let view = makeView()
        let before = topVisibleLine(view)

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        XCTAssertEqual(view.presentedScrollRows, 1.0 / 3.0, accuracy: 1e-6, "after one point of three")
        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        XCTAssertEqual(view.presentedScrollRows, 2.0 / 3.0, accuracy: 1e-6, "after two points of three")

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        XCTAssertEqual(view.presentedScrollRows, 1, accuracy: 1e-6,
                       "three points of precise motion did not add up to one row")
        // On a whole row the picture is a plain frame again: the engine is
        // where the eye is and nothing is being translated.
        XCTAssertEqual(CGFloat(view.viewportOffset), view.presentedScrollRows, accuracy: 1e-9)
        XCTAssertNotEqual(topVisibleLine(view), before,
                          "a whole row of motion did not change the top line")
    }

    /// A notched wheel already reports lines. Reading it in the same units as
    /// a trackpad rounded every notch to zero, which is why a promotion of any
    /// sub-threshold event to a whole row had to exist -- and that promotion
    /// is what made trackpad motion jump.
    func testOneWheelNotchMovesOneRow() throws {
        let view = makeView()
        let before = topVisibleLine(view)

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: false)))

        XCTAssertNotEqual(topVisibleLine(view), before,
                          "a wheel notch scrolled nothing")
    }

    /// Reversal inside a gesture cancels rather than moving twice.
    func testOppositePreciseMotionCancels() throws {
        let view = makeView()
        let before = topVisibleLine(view)

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 2, precise: true)))
        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: -2, precise: true)))

        XCTAssertEqual(topVisibleLine(view), before,
                       "equal and opposite motion left the viewport moved")
        XCTAssertEqual(view.presentedScrollRows, 0, accuracy: 1e-6,
                       "a reversal did not come back to where it started")
    }

    /// A program that asked for mouse reports gets the wheel as its own event,
    /// and the local scrollback must not move underneath it.
    func testAlternateScreenMouseReportingStillTakesPrecedence() throws {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        // Alternate screen plus SGR mouse reporting, as a TUI would set.
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1006h\u{1b}[?1000h".utf8))
        let before = topVisibleLine(view)
        // Enabling the modes already replied to the program, so a report has
        // to be counted from here rather than from empty.
        let baseline = reportCount(delegate)

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 3, precise: false)))

        XCTAssertEqual(reportCount(delegate), baseline + 3,
                       "each normal wheel step must reach the program that asked for it")
        XCTAssertEqual(topVisibleLine(view), before,
                       "local scrollback moved under a program receiving mouse reports")
        XCTAssertEqual(view.presentedScrollRows, 0, accuracy: 1e-9,
                       "a reporting mode must not leave the grid translated")
    }

    /// A TUI must still hear a trackpad.
    ///
    /// Rounding each precise event on its own throws away everything under one
    /// step, so slow trackpad movement reported nothing at all to the program.
    /// The baseline avoided that by promoting every sub-threshold event to a
    /// full report; carrying the remainder does it without over-reporting.
    func testSmallPreciseMotionIsStillReportedToTheProgram() throws {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1006h\u{1b}[?1000h".utf8))

        let baseline = reportCount(delegate)

        // Three points, one at a time: each on its own is a third of a step
        // and rounds to nothing.
        for _ in 0..<3 {
            view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        }

        XCTAssertEqual(reportCount(delegate), baseline + 1,
                       "small precise motion was dropped instead of reported")
        XCTAssertEqual(view.presentedScrollRows, 0, accuracy: 1e-9,
                       "a reporting mode must not translate the grid")
    }

    /// Both directions, and a reversal in the middle, with nothing dropped and
    /// nothing translated. Momentum events arrive on this same precise path.
    func testPreciseReportingCarriesInBothDirectionsAndThroughReversal() throws {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1006h\u{1b}[?1000h".utf8))

        let baseline = reportCount(delegate)
        let before = topVisibleLine(view)

        for _ in 0..<3 {
            view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        }
        XCTAssertEqual(reportCount(delegate), baseline + 1,
                       "upward precise motion reported nothing")

        // Straight into the opposite direction: the carried remainder is zero
        // at this point, so three more points make the step the other way.
        for _ in 0..<3 {
            view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: -1, precise: true)))
        }
        XCTAssertEqual(reportCount(delegate), baseline + 2,
                       "downward precise motion after a reversal reported nothing")

        XCTAssertEqual(view.presentedScrollRows, 0, accuracy: 1e-9)
        XCTAssertEqual(topVisibleLine(view), before,
                       "local scrollback must not move under a reporting program")
    }

    /// The rate the protocol sees is bounded by motion, not by event count:
    /// no report for motion that has not yet reached a step.
    func testReportingRateIsBoundedByMotionNotByEventCount() throws {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1006h\u{1b}[?1000h".utf8))

        // Two points is two thirds of a step: nothing whole yet, so nothing
        // reported -- but it is carried, not discarded.
        let baseline = reportCount(delegate)
        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        XCTAssertEqual(reportCount(delegate), baseline,
                       "reported a step the finger had not travelled")
        XCTAssertEqual(view.pendingWheelReportSteps, 2.0 / 3.0, accuracy: 1e-6,
                       "the motion was discarded rather than carried")

        // The third point completes the step.
        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        XCTAssertEqual(reportCount(delegate), baseline + 1)
    }

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
}
#endif
