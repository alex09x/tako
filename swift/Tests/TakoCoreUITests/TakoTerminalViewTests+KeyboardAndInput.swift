/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(UIKit)
import Foundation
import Metal
import QuartzCore
import UIKit
import XCTest
@testable import TakoCoreUI

@MainActor
extension TakoTerminalViewTests {
    func testInitializationAndDefaults() {
        let core = TakoCore(cols: 80, rows: 24)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), core: core)
        XCTAssertEqual(view.cols, 80)
        XCTAssertEqual(view.rows, 24)
        XCTAssertEqual(view.viewportOffset, 0)
        XCTAssertEqual(view.scrollbackLength, 0)
        XCTAssertTrue(view.autoFocusKeyboardOnTap)
        XCTAssertTrue(view.canBecomeFirstResponder)
        XCTAssertTrue(view.hasText)
    }

    func testFeedAndDeviceReply() {
        let core = TakoCore(cols: 80, rows: 24)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), core: core)
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let testText = "Hello TakoTerminalView\r\n"
        view.feed(data: Data(testText.utf8))

        let plainText = view.plainText(startRow: 0, maxRows: 5)
        XCTAssertTrue(plainText.contains("Hello TakoTerminalView"))

        // Feed DSR query sequence \e[5n
        view.feed(data: Data("\u{001B}[5n".utf8))
        XCTAssertFalse(delegate.deviceReplyDataReceived.isEmpty)
    }

    func testPTYOutputAndSplitUTF8Chunks() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // Multi-byte UTF-8 emoji "🎉" is [0xF0, 0x9F, 0x8E, 0x89]
        let chunk1 = Data([0xF0, 0x9F])
        let chunk2 = Data([0x8E, 0x89, 0x20, 0x54, 0x65, 0x73, 0x74, 0x0D, 0x0A]) // "🎉 Test\r\n"

        view.feed(data: chunk1)
        // Mid-sequence feed should not crash
        view.feed(data: chunk2)

        let text = view.plainText(startRow: 0, maxRows: 2)
        XCTAssertTrue(text.contains("🎉 Test") || text.contains("Test"))
    }

    func testSoftwareKeyboardInput() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.insertText("a")
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "a")

        delegate.inputDataReceived = Data()
        view.insertText("\n")
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)

        delegate.inputDataReceived = Data()
        view.deleteBackward()
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(delegate.inputDataReceived.first, 0x7f)

        delegate.inputDataReceived = Data()
        view.insertText("e\u{0301}")
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "e\u{0301}")

        delegate.inputDataReceived = Data()
        view.insertText("👨‍👩‍👧‍👦")
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "👨‍👩‍👧‍👦")
    }

    func testHardwareInputOrderingAndKeyCommands() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let keyCommands = view.keyCommands
        XCTAssertNotNil(keyCommands)
        XCTAssertFalse(keyCommands?.isEmpty ?? true)

        let sel = Selector(("handleKeyCommand:"))

        // Test Up Arrow command
        let upCommand = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: sel)
        _ = view.perform(sel, with: upCommand)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)

        // Test Ctrl+C command
        delegate.inputDataReceived = Data()
        let ctrlCCommand = UIKeyCommand(input: "c", modifierFlags: .control, action: sel)
        _ = view.perform(sel, with: ctrlCCommand)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(delegate.inputDataReceived, Data([0x03]))
    }

    func testAlternateScreenPromptCtrlCQuickKeyUsesInterruptByte() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        // Alternate screen + Kitty flag 1.
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?2004h\u{1b}[=1;1u\u{1b}[?u".utf8))
        XCTAssertEqual(view.core.kittyKeyboardFlags(), 1)

        view.feed(data: Data("prompt> draft text".utf8))

        let sel = Selector(("handleKeyCommand:"))
        let ctrlCCommand = UIKeyCommand(input: "c", modifierFlags: .control, action: sel)
        _ = view.perform(sel, with: ctrlCCommand)

        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(delegate.inputDataReceived, Data([0x03]), "Ctrl+C in an alternate-screen prompt must emit 0x03")
    }

    func testEveryNativeUserInputPathReturnsFromScrollbackToTheLiveScreen() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let history = (1...80)
            .map { "History line \($0)\r\n" }
            .joined()
        view.feed(data: Data(history.utf8))
        XCTAssertGreaterThan(view.scrollbackLength, 0)

        func parkInHistory() {
            view.scrollViewportUp(lines: 5)
            XCTAssertGreaterThan(view.viewportOffset, 0)
            view.feed(data: Data("background output\r\n".utf8))
            XCTAssertLessThan(delegate.scrollPositions.last ?? 1, 1)
        }

        parkInHistory()
        view.insertText("a")
        XCTAssertEqual(view.viewportOffset, 0)

        parkInHistory()
        view.deleteBackward()
        XCTAssertEqual(view.viewportOffset, 0)

        parkInHistory()
        let selector = Selector(("handleKeyCommand:"))
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: selector)
        _ = view.perform(selector, with: up)
        XCTAssertEqual(view.viewportOffset, 0)

        parkInHistory()
        view.pasteStringProvider = { "pasted" }
        view.paste(nil)
        XCTAssertEqual(view.viewportOffset, 0)

        XCTAssertEqual(delegate.scrollPositions.last, 1, "the host must persist the live position")
    }

    func testResizeCallbacks() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        XCTAssertNotNil(delegate.lastResizedCols)
        XCTAssertNotNil(delegate.lastResizedRows)
        XCTAssertEqual(view.cols, delegate.lastResizedCols)
        XCTAssertEqual(view.rows, delegate.lastResizedRows)
    }

    func testResizeCallbacksIgnoreTransientRotationGeometry() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        // Rotation briefly reported a four-row portrait-sized surface before
        // the final keyboard-adjusted bounds. Applying that intermediate size
        // pushed the top of a short terminal into scrollback permanently.
        view.frame = CGRect(x: 0, y: 0, width: 760, height: 150)
        view.layoutSubviews()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        XCTAssertEqual(delegate.resizeCount, 1)
        XCTAssertEqual(view.cols, Int(view.bounds.width / view.renderer.metrics.cellWidth))
        XCTAssertEqual(view.rows, Int(view.bounds.height / view.renderer.metrics.cellHeight))
    }

    func testAppliedOneRowRotationGeometryReturnsAdjacentHistoryToVisibleScreen() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 720, height: 120))
        view.layoutSubviews()
        view.flushPendingResizeForTesting()
        view.feed(data: Data("workspace · fixture pty ready\r\nПривет✓λ→\r\n$ ".utf8))

        // Reproduce the destructive geometry observed between landscape and
        // restored portrait. Unlike the debounce-only test above, this size
        // really applies, as it can when an orientation transition pauses.
        view.frame = CGRect(
            x: 0,
            y: 0,
            width: 720,
            height: view.renderer.metrics.cellHeight
        )
        view.layoutSubviews()
        view.flushPendingResizeForTesting()
        XCTAssertFalse(view.accessibilityValue?.contains("fixture pty ready") == true)
        XCTAssertTrue(view.bufferText.contains("fixture pty ready"))

        view.frame = CGRect(x: 0, y: 0, width: 402, height: 275)
        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        XCTAssertTrue(
            view.accessibilityValue?.contains("fixture pty ready") == true,
            "restored portrait left the banner outside the visible Metal viewport"
        )
        XCTAssertTrue(view.accessibilityValue?.contains("Привет✓λ→") == true)
        XCTAssertTrue(view.accessibilityValue?.contains("$") == true)
    }

    func testResetAndScroll() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        var text = ""
        for i in 1...50 {
            text += "Line \(i)\r\n"
        }
        view.feed(data: Data(text.utf8))

        XCTAssertGreaterThan(view.scrollbackLength, 0)

        view.scrollViewportUp(lines: 5)
        XCTAssertEqual(view.viewportOffset, 5)

        view.scrollViewportDown(lines: 2)
        XCTAssertEqual(view.viewportOffset, 3)

        view.scrollViewportToBottom()
        XCTAssertEqual(view.viewportOffset, 0)

        view.scrollToOffset(10)
        XCTAssertEqual(view.viewportOffset, 10)

        view.reset()
        view.scrollViewportToBottom()
        XCTAssertEqual(view.viewportOffset, 0)
    }

    func testSelectionAndCopy() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Hello Selection Test\r\n".utf8))

        XCTAssertNil(view.selectedText)
        XCTAssertFalse(view.core.hasSelection())

        // Start selection programmatically via core
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 5)

        XCTAssertTrue(view.core.hasSelection())
        XCTAssertNotNil(view.selectedText)

        // Clear selection via tap handler
        let tapSel = Selector(("handleTap:"))
        let tap = UITapGestureRecognizer()
        _ = view.perform(tapSel, with: tap)
        XCTAssertFalse(view.core.hasSelection())
    }

    func testAccessibilityText() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertEqual(view.accessibilityLabel, "Terminal")
        XCTAssertTrue(view.accessibilityTraits.contains(.updatesFrequently))

        view.feed(data: Data("Accessibility Line\r\n".utf8))
        let value = view.accessibilityValue
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.contains("Accessibility Line") ?? false)
    }


}
#endif
