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

    func testKeyboardInputEncoding() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            let eventA = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )!
            view.keyDown(with: eventA)
            XCTAssertEqual(delegate.inputDataReceived, Data("a".utf8))
            delegate.inputDataReceived.removeAll()

            let eventReturn = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )!
            view.keyDown(with: eventReturn)
            XCTAssertEqual(delegate.inputDataReceived, Data("\r".utf8))
            delegate.inputDataReceived.removeAll()

            let eventUp = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 126
            )!
            view.keyDown(with: eventUp)
            XCTAssertEqual(delegate.inputDataReceived, Data("\u{1b}[A".utf8))
            delegate.inputDataReceived.removeAll()

            let eventCtrlC = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{03}",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )!
            view.keyDown(with: eventCtrlC)
            XCTAssertEqual(delegate.inputDataReceived, Data([0x03]))
            delegate.inputDataReceived.removeAll()
        }
    }

    // MARK: - NSTextInputClient

    func testNSTextInputClientMarkedText() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            XCTAssertFalse(view.hasMarkedText())

            view.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 3))

            view.unmarkText()
            XCTAssertFalse(view.hasMarkedText())
        }
    }

    func testNSTextInputClientInsertText() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))

            XCTAssertFalse(view.hasMarkedText())
            XCTAssertEqual(delegate.inputDataReceived, Data("你好".utf8))
        }
    }

    func testFirstRectCalculation() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            XCTAssertGreaterThan(rect.size.width, 0)
            XCTAssertGreaterThan(rect.size.height, 0)
        }
    }

    // MARK: - Selection & Copy/Paste

    func testSelectionAndCopy() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.feed(data: Data("Copied Sample Text\r\n".utf8))

            var copiedText: String?
            view.copyStringConsumer = { text in copiedText = text }

            view.core.startSelection(row: 0, col: 0, mode: .linear)
            view.core.extendSelection(row: 0, col: 5)

            XCTAssertEqual(view.selectedText, "Copied")
            view.copy(nil)
            XCTAssertEqual(copiedText, "Copied")
        }
    }

    func testPasteAction() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.pasteStringProvider = { "Pasted String" }
            view.paste(nil)

            XCTAssertEqual(delegate.inputDataReceived, Data("Pasted String".utf8))
        }
    }

    func testBracketedPasteMode() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}[?2004h".utf8))

            view.pasteStringProvider = { "line1\nline2" }
            view.paste(nil)

            let pastedData = delegate.inputDataReceived
            let pastedStr = String(data: pastedData, encoding: .utf8) ?? ""
            XCTAssertTrue(pastedStr.hasPrefix("\u{1b}[200~"))
            XCTAssertTrue(pastedStr.hasSuffix("\u{1b}[201~"))
            XCTAssertTrue(pastedStr.contains("line1\rline2"))
        }
    }

    // MARK: - Mouse Reporting vs Local Selection

    func testMouseReportingWhenEnabled() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))

            let mouseDownEvent = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 50, y: 550),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1.0
            )!

            view.mouseDown(with: mouseDownEvent)
            XCTAssertFalse(delegate.inputDataReceived.isEmpty)
            let seq = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
            XCTAssertTrue(seq.hasPrefix("\u{1b}[<0;"))
            XCTAssertTrue(seq.hasSuffix("M"))
        }
    }

    // MARK: - Synchronized Output

    func testSynchronizedOutputHolding() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}[?2026h".utf8))
            XCTAssertTrue(view.core.isSynchronizedOutputActive())

            view.feed(data: Data("Mid-sync text".utf8))

            view.feed(data: Data("\u{1b}[?2026l".utf8))
            XCTAssertFalse(view.core.isSynchronizedOutputActive())
            XCTAssertTrue(view.plainText(startRow: 0, maxRows: 1).contains("Mid-sync text"))
        }
    }

    // MARK: - Presentation pause and cursor blink

}
