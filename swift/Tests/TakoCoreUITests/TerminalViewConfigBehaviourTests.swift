import XCTest
@testable import TakoCoreUI

#if canImport(AppKit)
import AppKit

/// The terminal view's share of the config: the cursor it shows while the
/// program has chosen none, hiding the pointer while typing, and telling
/// its host when a selection is finished.
@MainActor
final class TerminalViewConfigBehaviourTests: XCTestCase {
    func testCursorStyleIsParsedFromTheConfig() {
        XCTAssertEqual(TerminalTheme.parse(config: "cursor-style = bar").cursorShape, .bar)
        XCTAssertEqual(TerminalTheme.parse(config: "cursor-style = underline").cursorShape, .underline)
        XCTAssertEqual(TerminalTheme.parse(config: "cursor-style = block_hollow").cursorShape, .block)
        XCTAssertEqual(TerminalTheme.parse(config: "cursor-style = triangle").cursorShape, .block)
    }

    func testTheThemesCursorIsTheEnginesDefaultUntilAProgramChoosesOne() {
        var theme = TerminalTheme.takoDefault
        theme.cursorShape = .bar
        theme.cursorBlink = false
        let core = TakoCore(cols: 20, rows: 2)
        let view = TakoTerminalNSView(core: core, theme: theme)

        XCTAssertEqual(core.cursorStyle().shape, .bar)
        XCTAssertFalse(core.cursorStyle().blinking)

        core.feed(bytes: Data("\u{1b}[3 q".utf8))
        theme.cursorShape = .block
        view.theme = theme
        XCTAssertEqual(core.cursorStyle().shape, .underline, "the program's choice stays")

        core.feed(bytes: Data("\u{1b}[0 q".utf8))
        XCTAssertEqual(core.cursorStyle().shape, .block, "DECSCUSR 0 returns to the theme's")
    }

    private func keyEvent(_ text: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
    }

    func testTypingHidesThePointerOnlyWhenAsked() {
        var hides = 0
        let original = TakoTerminalNSView.hideMouseUntilMoved
        TakoTerminalNSView.hideMouseUntilMoved = { hides += 1 }
        defer { TakoTerminalNSView.hideMouseUntilMoved = original }
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

        view.keyDown(with: keyEvent("a"))
        XCTAssertEqual(hides, 0)

        view.hidesMouseWhileTyping = true
        view.keyDown(with: keyEvent("b"))
        XCTAssertEqual(hides, 1)
    }

    private final class RecordingView: TakoTerminalNSView {
        var finished = 0
        override func selectionDidFinish() { finished += 1 }
    }

    private func mouseUp(in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    func testAPressThatLeavesASelectionReportsItFinished() {
        let view = RecordingView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(data: Data("hello world".utf8))

        view.mouseUp(with: mouseUp(in: view))
        XCTAssertEqual(view.finished, 0, "nothing selected, nothing to report")

        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 4)
        view.mouseUp(with: mouseUp(in: view))
        XCTAssertEqual(view.finished, 1)
    }
}
#endif
