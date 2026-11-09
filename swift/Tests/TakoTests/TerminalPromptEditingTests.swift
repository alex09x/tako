/*
 * tako — Prompt editing shortcuts must belong to their field editor
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@MainActor @Suite(.serialized)
struct TerminalPromptEditingTests {
    @Test func commandAReplacesTheOldPromptValueInsteadOfAppending() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let answer = Task { @MainActor in
            await TerminalDialogView.askText(in: window, title: "Rename", label: "Name", value: "Old name",
                                            hint: nil, confirm: "Rename", theme: nil)
        }
        for _ in 0..<20 {
            await Task.yield()
            if window.contentView?.subviews.contains(where: { $0 is TerminalDialogView }) == true { break }
        }
        let prompt = try #require(window.contentView?.subviews.compactMap { $0 as? TerminalDialogView }.first)
        let editable = prompt.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }
        let field = try #require(editable)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        // Reproduce a physical click placing the caret at the old text's end.
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let select = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(prompt.performKeyEquivalent(with: select))
        #expect(editor.selectedRange().length == "Old name".utf16.count)
        editor.insertText("New name", replacementRange: editor.selectedRange())
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        prompt.keyDown(with: enter)
        #expect(await answer.value == "New name")
    }
}
