import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// `link-url` (Command-hover underlines and Command-click opens a detected
/// URL or OSC 8 hyperlink) and `cursor-click-to-move` (a plain click on the
/// cursor's own prompt line walks the cursor there with arrow keys).
@MainActor
final class TakoTerminalNSViewLinkAndCursorClickTests: XCTestCase {
    private func makeView() -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func point(forColumn col: Int, row: Int = 0, in view: TakoTerminalNSView) -> NSPoint {
        let origin = view.cellOrigin(row: row, col: col)
        return NSPoint(x: origin.x + max(view.cellWidth, 1) / 2,
                       y: origin.y + max(view.cellHeight, 1) / 2)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, column: Int, row: Int = 0, in view: TakoTerminalNSView,
        modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point(forColumn: column, row: row, in: view),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }

    private func withOpener(_ opener: @escaping (URL) -> Void, _ body: () -> Void) {
        let previous = TakoTerminalNSView.openURL
        TakoTerminalNSView.openURL = opener
        defer { TakoTerminalNSView.openURL = previous }
        body()
    }

    // MARK: - link-url: plain-text URL detection

    func testCommandClickOnAPlainURLOpensIt() {
        let view = makeView()
        view.feed(data: Data("see https://example.com/path for docs".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 10, in: view, modifiers: [.command]))
        }
        XCTAssertEqual(opened, [URL(string: "https://example.com/path")!])
    }

    func testCommandHoverOverAURLUnderlinesItAndSetsThePointingHandCursor() {
        let view = makeView()
        view.feed(data: Data("see https://example.com/path for docs".utf8))
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 10, in: view, modifiers: [.command]))
        XCTAssertEqual(view.hoveredLink?.url, URL(string: "https://example.com/path")!)

        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 10, in: view, modifiers: []))
        XCTAssertNil(view.hoveredLink, "releasing Command must clear the hover")
    }

    /// The bug this pins: deleting the flag check would make every URL
    /// clickable, which the disabled test below would silently pass through.
    func testLinkURLDisabledLeavesPlainURLsUnclickable() {
        let view = makeView()
        view.linkURLDetectionEnabled = false
        view.feed(data: Data("see https://example.com/path for docs".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 10, in: view, modifiers: [.command]))
        }
        XCTAssertTrue(opened.isEmpty)
    }

    func testCommandClickWithoutAURLStartsNoOpener() {
        let view = makeView()
        view.feed(data: Data("no links here".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 2, in: view, modifiers: [.command]))
        }
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - link-url: OSC 8 hyperlinks keep working regardless of the flag

    func testCommandClickOnAnOSC8HyperlinkOpensItsURI() {
        let view = makeView()
        view.linkURLDetectionEnabled = false
        view.feed(data: Data("\u{1b}]8;;http://osc8.example\u{7}click me\u{1b}]8;;\u{7}".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 2, in: view, modifiers: [.command]))
        }
        XCTAssertEqual(opened, [URL(string: "http://osc8.example")!])
    }

    // MARK: - cursor-click-to-move

    private func leftArrowBytes(_ view: TakoTerminalNSView) -> Data {
        view.core.encodeKey(event: FfiKeyEvent(
            key: .left, text: "", physicalText: "", unshiftedText: "",
            shift: false, alt: false, ctrl: false, superKey: false,
            press: true, repeat: false, composing: false
        ))
    }

    private func rightArrowBytes(_ view: TakoTerminalNSView) -> Data {
        view.core.encodeKey(event: FfiKeyEvent(
            key: .right, text: "", physicalText: "", unshiftedText: "",
            shift: false, alt: false, ctrl: false, superKey: false,
            press: true, repeat: false, composing: false
        ))
    }

    private func click(column: Int, row: Int = 0, modifiers: NSEvent.ModifierFlags = [], in view: TakoTerminalNSView) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, column: column, row: row, in: view, modifiers: modifiers))
        view.mouseUp(with: mouseEvent(.leftMouseUp, column: column, row: row, in: view, modifiers: modifiers))
    }

    func testClickOnTheCursorsPromptLineMovesTheCursorLeft() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}]133;A\u{7}$ hello".utf8))
        XCTAssertTrue(view.core.cursorIsAtPrompt())
        XCTAssertEqual(view.core.cursorCol(), 7)
        delegate.inputDataReceived = Data()

        click(column: 2, in: view)

        let expected = Data((0..<5).map { _ in leftArrowBytes(view) }.reduce(Data(), +))
        XCTAssertEqual(delegate.inputDataReceived, expected)
    }

    func testClickRightOfTheCursorOnItsPromptLineMovesItRight() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}]133;A\u{7}$ hi".utf8))
        XCTAssertEqual(view.core.cursorCol(), 4)
        delegate.inputDataReceived = Data()

        click(column: 8, in: view)

        let expected = Data((0..<4).map { _ in rightArrowBytes(view) }.reduce(Data(), +))
        XCTAssertEqual(delegate.inputDataReceived, expected)
    }

    /// The disabled-key half of the contract: with the feature off, a click
    /// away from the cursor must not move it at all.
    func testCursorClickToMoveDisabledDoesNotMoveTheCursor() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.cursorClickToMove = false
        view.feed(data: Data("\u{1b}]133;A\u{7}$ hello".utf8))
        delegate.inputDataReceived = Data()

        click(column: 2, in: view)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    /// Not at a prompt (no OSC 133;A was ever seen on this row) -- a click
    /// elsewhere on the line must not be treated as cursor placement.
    func testClickAwayFromAPromptDoesNotMoveTheCursor() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("just some output, no prompt mark".utf8))
        delegate.inputDataReceived = Data()

        click(column: 2, in: view)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    /// Upstream also accepts Option+click anywhere on the prompt line, not
    /// only on the cursor's own row.
    func testOptionClickMovesTheCursorFromAnotherRowOnTheSamePrompt() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        // Two separate prompt rows, both marked by their own OSC 133;A; the
        // cursor sits on the second, and row 0 is not where it is -- only
        // Option+click reaches it.
        view.feed(data: Data("\u{1b}]133;A\u{7}$ first\r\n".utf8))
        view.feed(data: Data("\u{1b}]133;A\u{7}$ second".utf8))
        XCTAssertEqual(view.core.cursorRow(), 1)
        delegate.inputDataReceived = Data()

        click(column: 2, row: 0, in: view)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "a plain click off the cursor's row must not move it")

        click(column: 2, row: 0, modifiers: [.option], in: view)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty, "Option+click on another row of the same prompt must move the cursor")
    }
}
#endif
