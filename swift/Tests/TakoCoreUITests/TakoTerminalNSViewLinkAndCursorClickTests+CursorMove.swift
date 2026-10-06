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

@MainActor
extension TakoTerminalNSViewLinkAndCursorClickTests {

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

    func testStationaryPointerLinkHUDUpdatesOnTerminalContentChange() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}]8;;https://example.com/first\u{7}LinkOne\u{1b}]8;;\u{7}".utf8))

        // Hover over the link at row 0, col 3
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 3, row: 0, in: view, modifiers: []))
        XCTAssertEqual(view.hoveredLinkTarget, "https://example.com/first")
        XCTAssertEqual(view.toolTip, "https://example.com/first")

        // New output arrives that overwrites row 0 with plain non-link text
        view.feed(data: Data("\u{1b}[HPlain text without links here".utf8))
        view.redrawNow()

        // Without any mouseMoved event, hoveredLinkTarget and tooltip must be cleared or updated
        XCTAssertNil(view.hoveredLinkTarget)
        XCTAssertNil(view.toolTip)
    }

    func testWrappedOSC8LinkDetectsMismatchAcrossRows() {
        let view = makeView()
        // Row 0 has "https://" (cols 72..79) and soft-wraps onto Row 1 with "paypal.com/login" (cols 0..15)
        // Both cells belong to the same OSC 8 hyperlink targeting https://attacker.org/steal
        let padCols = Int(view.core.cols()) - 8
        let padding = String(repeating: " ", count: max(0, padCols))
        let payload = "\(padding)\u{1b}]8;;https://attacker.org/steal\u{7}https://paypal.com/login\u{1b}]8;;\u{7}"
        view.feed(data: Data(payload.utf8))

        // Check link at row 0 (contains only "https://")
        let linkRow0 = view.linkRange(at: (row: 0, col: Int(view.core.cols()) - 4))
        XCTAssertNotNil(linkRow0)
        XCTAssertTrue(linkRow0?.isMismatch ?? false, "Wrapped link on row 0 must detect mismatch from full assembled text")
        XCTAssertTrue(linkRow0?.text.contains("paypal.com") ?? false)

        // Check link at row 1 (contains "paypal.com/login")
        let linkRow1 = view.linkRange(at: (row: 1, col: 4))
        XCTAssertNotNil(linkRow1)
        XCTAssertTrue(linkRow1?.isMismatch ?? false, "Wrapped link on row 1 must detect mismatch from full assembled text")
        XCTAssertTrue(linkRow1?.text.contains("https://") ?? false)

        // Command-clicking row 0 prompts for mismatch confirmation
        var opened: [URL] = []
        var observedWarning: TakoTerminalNSView.LinkSecurityWarning?
        withConfirmOpenURL({ _, warning, _, completion in
            observedWarning = warning
            completion(false)
        }) {
            withOpener({ opened.append($0) }) {
                view.mouseDown(with: mouseEvent(.leftMouseDown, column: Int(view.core.cols()) - 4, row: 0, in: view, modifiers: [.command]))
            }
        }
        XCTAssertNotNil(observedWarning)
        if case .urlMismatch(let text, let target) = observedWarning {
            XCTAssertTrue(text.contains("paypal.com"))
            XCTAssertEqual(target, URL(string: "https://attacker.org/steal")!)
        } else {
            XCTFail("Expected urlMismatch warning on row 0")
        }
        XCTAssertTrue(opened.isEmpty)
    }

    func testHardEndedRowWithSameURIAtNextRowCol0DoesNotMerge() {
        let view = makeView()
        // Row 0 has "x" at the final column (cols - 1) and ends with a hard CRLF
        // Row 1 starts at col 0 with "https://paypal.com/login" targeting the same attacker URI
        let padCols = Int(view.core.cols()) - 1
        let padding = String(repeating: " ", count: max(0, padCols))
        let payload = "\(padding)\u{1b}]8;;https://attacker.org/steal\u{7}x\u{1b}]8;;\u{7}\r\n\u{1b}]8;;https://attacker.org/steal\u{7}https://paypal.com/login\u{1b}]8;;\u{7}"
        view.feed(data: Data(payload.utf8))

        // Hover over row 1 col 4 (in "https://paypal.com/login")
        let linkRow1 = view.linkRange(at: (row: 1, col: 4))
        XCTAssertNotNil(linkRow1)
        XCTAssertEqual(linkRow1?.text, "https://paypal.com/login", "Must not merge 'x' across hard-ended row boundary")
        XCTAssertTrue(linkRow1?.isMismatch ?? false, "Deceptive domain on row 1 must be flagged as mismatch")

        // Hover over row 0 at the last column ("x")
        let linkRow0 = view.linkRange(at: (row: 0, col: Int(view.core.cols()) - 1))
        XCTAssertNotNil(linkRow0)
        XCTAssertEqual(linkRow0?.text, "x", "Must contain only row 0 span text")
        XCTAssertFalse(linkRow0?.isMismatch ?? true, "Plain 'x' is not URL-shaped and not a deceptive mismatch")
    }

    func testMultipleOSC8SpansWithSameURIOnSameRowDoNotMergeInterveningText() {
        let view = makeView()
        // Row contains:
        // col 0: OSC 8 span displaying "x" targeting https://attacker.org/steal
        // col 1..10: Plain text " spaces " without hyperlink
        // col 11..35: OSC 8 span displaying "https://paypal.com/login" targeting https://attacker.org/steal
        let payload = "\u{1b}]8;;https://attacker.org/steal\u{7}x\u{1b}]8;;\u{7}  spaces  \u{1b}]8;;https://attacker.org/steal\u{7}https://paypal.com/login\u{1b}]8;;\u{7}"
        view.feed(data: Data(payload.utf8))

        // Hover over the second span at col 15 (in "https://paypal.com/login")
        let linkSecond = view.linkRange(at: (row: 0, col: 15))
        XCTAssertNotNil(linkSecond)
        XCTAssertEqual(linkSecond?.text, "https://paypal.com/login", "Must not merge 'x' or intervening spaces from distinct span")
        XCTAssertTrue(linkSecond?.isMismatch ?? false, "Deceptive domain in second span must be flagged as mismatch")

        // Hover over the first span at col 0 ("x")
        let linkFirst = view.linkRange(at: (row: 0, col: 0))
        XCTAssertNotNil(linkFirst)
        XCTAssertEqual(linkFirst?.text, "x", "Must contain only the clicked span text")
        XCTAssertFalse(linkFirst?.isMismatch ?? true, "Plain 'x' is not URL-shaped and not a deceptive mismatch")
    }
}
#endif

}
