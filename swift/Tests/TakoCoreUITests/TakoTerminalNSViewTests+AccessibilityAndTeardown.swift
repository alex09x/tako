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

extension TakoTerminalNSViewTests {

    func testAccessibilityProperties() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.feed(data: Data("Accessibility Content".utf8))

            XCTAssertTrue(view.plainText(startRow: 0, maxRows: view.rows).contains("Accessibility Content"))
            XCTAssertEqual(view.accessibilityRole(), .textArea)
            XCTAssertEqual(view.accessibilityLabel(), "Terminal")
        }
    }

    func testDeterministicTeardown() {
        MainActor.assumeIsolated {
            var view: TakoTerminalNSView? = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view?.feed(data: Data("Transient view content".utf8))
            XCTAssertNotNil(view)
            view = nil
            XCTAssertNil(view)
        }
    }

    func testNSTextInputClientProtocolConformance() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            guard let client = view as (any NSTextInputClient)? else {
                XCTFail("TakoTerminalNSView must conform to NSTextInputClient")
                return
            }
            XCTAssertFalse(client.hasMarkedText())
            XCTAssertEqual(client.markedRange(), NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(client.selectedRange(), NSRange(location: 0, length: 0))
            XCTAssertTrue(client.validAttributesForMarkedText().isEmpty)
            XCTAssertEqual(client.characterIndex(for: NSPoint.zero), 0)
            XCTAssertNil(client.attributedSubstring(forProposedRange: NSRange(location: 0, length: 0), actualRange: nil))

            client.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(client.hasMarkedText())
            XCTAssertEqual(client.markedRange(), NSRange(location: 0, length: 3))

            client.unmarkText()
            XCTAssertFalse(client.hasMarkedText())

            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate
            client.insertText("xyz", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        }
    }

    func testBlinkTimerCallbackTogglesBlinkState() async throws {
        let view = await MainActor.run { () -> TakoTerminalNSView in
            var blinking = TerminalTheme.takoDefault
            blinking.cursorBlink = true
            let v = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), theme: blinking)
            XCTAssertTrue(v.isBlinkStateVisibleForTesting)
            v.blinkTimer?.fire()
            return v
        }

        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
            let toggled = await MainActor.run { !view.isBlinkStateVisibleForTesting }
            if toggled { break }
        }

        await MainActor.run {
            XCTAssertFalse(view.isBlinkStateVisibleForTesting, "firing blinkTimer should toggle blinkStateVisible to false")
            view.blinkTimer?.fire()
        }

        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
            let toggledBack = await MainActor.run { view.isBlinkStateVisibleForTesting }
            if toggledBack { break }
        }

        await MainActor.run {
            XCTAssertTrue(view.isBlinkStateVisibleForTesting, "firing blinkTimer again should toggle blinkStateVisible back to true")
        }
    }

    @MainActor
    func testTerminalViewEmitsPromptMarkDelegateCall() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}]133;A\u{07}".utf8))
        XCTAssertEqual(delegate.promptMarkCount, 1, "OSC 133;A must emit prompt mark delegate call")
    }

    @MainActor
    func testTerminalViewEmitsStatusDelegateCalls() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate

        // OSC 1337 SetStatus
        view.feed(data: Data("\u{1b}]1337;SetStatus=working;compiling Tako\u{07}".utf8))
        XCTAssertEqual(delegate.reportedStatuses.count, 1)
        XCTAssertEqual(delegate.reportedStatuses.first?.status, "working")
        XCTAssertEqual(delegate.reportedStatuses.first?.text, "compiling Tako")

        // OSC 1337 ClearStatus
        view.feed(data: Data("\u{1b}]1337;ClearStatus\u{07}".utf8))
        XCTAssertEqual(delegate.clearStatusCount, 1)

        // OSC 9;5 status
        view.feed(data: Data("\u{1b}]9;5;waiting_for_input;prompt text\u{07}".utf8))
        XCTAssertEqual(delegate.reportedStatuses.count, 2)
        XCTAssertEqual(delegate.reportedStatuses.last?.status, "waiting_for_input")
        XCTAssertEqual(delegate.reportedStatuses.last?.text, "prompt text")

        // OSC 9;5 clear
        view.feed(data: Data("\u{1b}]9;5;clear\u{07}".utf8))
        XCTAssertEqual(delegate.clearStatusCount, 2)
    }
}
#endif

}
