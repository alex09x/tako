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
import Carbon
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension TakoTerminalNSViewCoverageTests {

    func testCopyPasteAndSelectAll() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        var copied: String?
        view.copyStringConsumer = { copied = $0 }

        view.copy(nil)
        XCTAssertNil(copied)

        view.feed(data: Data("Text to copy\r\n".utf8))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 4)
        view.copy(nil)
        XCTAssertEqual(copied, "Text")

        view.pasteStringProvider = { nil }
        view.paste(nil)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)

        let pasteLines = (0..<30).map { "Line \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(pasteLines.utf8))
        view.scrollViewportUp(lines: 5)
        XCTAssertGreaterThan(view.viewportOffset, 0)

        view.pasteStringProvider = { "Pasted Live" }
        view.paste(nil)
        XCTAssertEqual(view.viewportOffset, 0)
        XCTAssertEqual(delegate.inputDataReceived, Data("Pasted Live".utf8))

        view.selectAll(nil)
        XCTAssertTrue(view.core.hasSelection())
    }

    // MARK: - 13. Drag and Drop

    func testDraggingEnteredAndPerformDragOperation() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        let emptyPasteboard = NSPasteboard.withUniqueName()
        let emptySender = MockDraggingInfo(pasteboard: emptyPasteboard)
        XCTAssertEqual(view.draggingEntered(emptySender), [])
        XCTAssertFalse(view.performDragOperation(emptySender))

        let urlPasteboard = NSPasteboard.withUniqueName()
        let url1 = URL(fileURLWithPath: "/tmp/path with space/file1.txt")
        let url2 = URL(fileURLWithPath: "/tmp/normal_file2.txt")
        urlPasteboard.writeObjects([url1 as NSURL, url2 as NSURL])
        let urlSender = MockDraggingInfo(pasteboard: urlPasteboard)
        XCTAssertEqual(view.draggingEntered(urlSender), .copy)

        let dragLines = (0..<30).map { "Drag \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(dragLines.utf8))
        view.scrollViewportUp(lines: 5)
        XCTAssertGreaterThan(view.viewportOffset, 0)
        XCTAssertTrue(view.performDragOperation(urlSender))
        XCTAssertEqual(view.viewportOffset, 0)
        let pastedURLs = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(pastedURLs.contains("'/tmp/path with space/file1.txt'"))
        XCTAssertTrue(pastedURLs.contains("/tmp/normal_file2.txt"))

        delegate.inputDataReceived.removeAll()
        let strPasteboard = NSPasteboard.withUniqueName()
        strPasteboard.setString("Dropped Raw String", forType: .string)
        let strSender = MockDraggingInfo(pasteboard: strPasteboard)
        XCTAssertEqual(view.draggingEntered(strSender), .copy)
        XCTAssertTrue(view.performDragOperation(strSender))
        XCTAssertEqual(delegate.inputDataReceived, Data("Dropped Raw String".utf8))

        // Shell-quoting tests
        XCTAssertEqual(TakoTerminalNSView.shellQuote(""), "''")
        XCTAssertEqual(TakoTerminalNSView.shellQuote("/usr/bin/env"), "/usr/bin/env")
        XCTAssertEqual(TakoTerminalNSView.shellQuote("/tmp/my file.txt"), "'/tmp/my file.txt'")
        XCTAssertEqual(TakoTerminalNSView.shellQuote("/tmp/bob's.txt"), "'/tmp/bob'\"'\"'s.txt'")
        XCTAssertEqual(TakoTerminalNSView.shellQuote("/tmp/$HOME/a;b.txt"), "'/tmp/$HOME/a;b.txt'")

        // Dropped hostile text with C0/C1/DEL controls is sanitized
        delegate.inputDataReceived.removeAll()
        let hostilePasteboard = NSPasteboard.withUniqueName()
        hostilePasteboard.setString("hello\u{0003}\u{001b}[31m\u{009b}2J\u{007f}world\r\n", forType: .string)
        let hostileSender = MockDraggingInfo(pasteboard: hostilePasteboard)
        XCTAssertTrue(view.performDragOperation(hostileSender))
        // Control chars stripped, newlines normalized to \r
        XCTAssertEqual(delegate.inputDataReceived, Data("hello[31m2Jworld\r".utf8))
    }

    // MARK: - 14. Services Menu

    func testServicesMenuValidationAndDataTransfer() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        XCTAssertNil(view.validRequestor(forSendType: .string, returnType: .string))
        XCTAssertNotNil(view.validRequestor(forSendType: nil, returnType: .string))

        view.feed(data: Data("Service Selection\r\n".utf8))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 7)

        XCTAssertTrue((view.validRequestor(forSendType: .string, returnType: .string) as? AnyObject) === view)
        XCTAssertTrue((view.validRequestor(forSendType: .string, returnType: nil) as? AnyObject) === view)

        let pboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(view.writeSelection(to: pboard, types: [.string]))
        XCTAssertEqual(pboard.string(forType: .string), "Service")

        view.core.clearSelection()
        XCTAssertFalse(view.writeSelection(to: pboard, types: [.string]))

        pboard.clearContents()
        pboard.setString("Service Output", forType: .string)
        let serviceLines = (0..<30).map { "Svc \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(serviceLines.utf8))
        view.scrollViewportUp(lines: 5)
        XCTAssertGreaterThan(view.viewportOffset, 0)
        XCTAssertTrue(view.readSelection(from: pboard))
        XCTAssertEqual(view.viewportOffset, 0)
        XCTAssertEqual(delegate.inputDataReceived, Data("Service Output".utf8))

        let emptyPboard = NSPasteboard.withUniqueName()
        XCTAssertFalse(view.readSelection(from: emptyPboard))
    }

    // MARK: - 15. NSTextInputClient & UI Validations

    func testNSTextInputClientMethods() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange().location, NSNotFound)
        XCTAssertEqual(view.selectedRange().length, 0)

        view.setMarkedText(NSAttributedString(string: "attr marked"), selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange().length, 11)

        view.setMarkedText(NSAttributedString(string: ""), selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())

        view.setMarkedText(12345, selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())

        view.setMarkedText("str marked", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        view.unmarkText() // idempotent

        XCTAssertEqual(view.validAttributesForMarkedText(), [])
        XCTAssertEqual(view.characterIndex(for: .zero), 0)

        XCTAssertNil(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 0), actualRange: nil))

        view.feed(data: Data("Selected Substring\r\n".utf8))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 8)
        let attr = view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 5), actualRange: nil)
        XCTAssertEqual(attr?.string, "Selected")

        view.insertText(NSAttributedString(string: "\n"), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(delegate.inputDataReceived, Data("\r".utf8))
        delegate.inputDataReceived.removeAll()

        view.insertText("\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(delegate.inputDataReceived, Data("\r".utf8))
        delegate.inputDataReceived.removeAll()

        view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(delegate.inputDataReceived, Data("z".utf8))
        delegate.inputDataReceived.removeAll()

        view.insertText("bulk inserted string", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(delegate.inputDataReceived, Data("bulk inserted string".utf8))
        delegate.inputDataReceived.removeAll()

        view.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)

        view.insertText(999, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)

        view.keyTextAccumulator = "acc_"
        view.insertText("more", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.keyTextAccumulator, "acc_more")
        view.keyTextAccumulator = nil

        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    func testInputMethodViewRectAndComposingControlHelpers() {
        let normalRect = TakoTerminalNSView.inputMethodViewRect(
            cursorCol: 5,
            cursorRow: 2,
            cols: 80,
            rows: 24,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 480,
            range: NSRange(location: 0, length: 1)
        )
        XCTAssertEqual(normalRect.origin.x, 50)
        XCTAssertEqual(normalRect.size.width, 10)

        let zeroRangeRect = TakoTerminalNSView.inputMethodViewRect(
            cursorCol: 78,
            cursorRow: 2,
            cols: 80,
            rows: 24,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 480,
            range: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(zeroRangeRect.size.width, 0)
        XCTAssertEqual(zeroRangeRect.origin.x, 30)

        let overflowRect = TakoTerminalNSView.inputMethodViewRect(
            cursorCol: 70,
            cursorRow: 23,
            cols: 80,
            rows: 24,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 480,
            range: NSRange(location: 100, length: 0)
        )
        XCTAssertEqual(overflowRect.origin.x, 800)

        let zeroColsRect = TakoTerminalNSView.inputMethodViewRect(
            cursorCol: 0,
            cursorRow: 0,
            cols: 0,
            rows: 0,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 480,
            range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(zeroColsRect.origin.x, 0)

        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput("a", composing: false))
        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput(nil, composing: true))
        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput("", composing: true))
        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput("abc", composing: true))
        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput("z", composing: true))
        XCTAssertTrue(TakoTerminalNSView.shouldSuppressComposingControlInput("\u{08}", composing: true))
        XCTAssertTrue(TakoTerminalNSView.shouldSuppressComposingControlInput("\r", composing: true))
    }

    func testFirstRectWithoutAndWithWindow() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let rectWithoutWindow = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        XCTAssertGreaterThan(rectWithoutWindow.size.width, 0)

        let (hostedView, _) = makeHostedView()
        let rectWithWindow = hostedView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        XCTAssertGreaterThan(rectWithWindow.size.width, 0)
    }

    func testValidateUserInterfaceItem() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let copyItem = MockValidatedItem(action: #selector(TakoTerminalNSView.copy(_:)))
        let pasteItem = MockValidatedItem(action: #selector(TakoTerminalNSView.paste(_:)))
        let selectAllItem = MockValidatedItem(action: #selector(TakoTerminalNSView.selectAll(_:)))
        let unknownItem = MockValidatedItem(action: #selector(NSResponder.indent(_:)))

        XCTAssertFalse(view.validateUserInterfaceItem(copyItem))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 5)
        XCTAssertTrue(view.validateUserInterfaceItem(copyItem))

        // Supply the paste source explicitly: the real pasteboard's contents
        // depend on the machine the suite runs on.
        view.pasteStringProvider = { "clipboard text" }
        XCTAssertTrue(view.validateUserInterfaceItem(pasteItem))
        view.pasteStringProvider = { nil }
        XCTAssertFalse(view.validateUserInterfaceItem(pasteItem))

        XCTAssertTrue(view.validateUserInterfaceItem(selectAllItem))
        XCTAssertFalse(view.validateUserInterfaceItem(unknownItem))
    }

    // MARK: - 16. CPU Draw & Presentation Logic

    func testCPUDrawVariants() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.feed(data: Data("Draw test line 1\r\nDraw test line 2\r\n".utf8))

        view.isPresentationPaused = true
        drawForTesting(view)

        view.isPresentationPaused = false
        view.scheduleRedraw()
        drawForTesting(view)

        var semiTransparent = TerminalTheme.takoDefault
        semiTransparent.backgroundOpacity = 0.5
        view.theme = semiTransparent
        view.scheduleRedraw()
        drawForTesting(view)

        view.setMarkedText("MarkedInDraw", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.scheduleRedraw()
        drawForTesting(view)

        view.needsDisplay = false
        XCTAssertFalse(view.needsDisplay)
        view.needsDisplay = true
        XCTAssertTrue(view.redrawPending)
        view.setNeedsDisplay(NSRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertTrue(view.redrawPending)

        view.displayLinkFired()
    }
}
#endif
