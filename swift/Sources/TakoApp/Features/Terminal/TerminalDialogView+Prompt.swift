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

extension TerminalDialogView {
    /// Asks in `window` and answers whether the user confirmed: `confirm`
    /// (destructive) or `cancel`. Nil when the window has no content view.
    static func ask(in window: NSWindow, title: String, message: String,
                    confirm: String, cancel: String = "Cancel",
                    promptId: String? = nil,
                    theme: TerminalTheme?) async -> Bool? {
        // The safe choice is on the left, the confirm on the right and chosen.
        let answer = await choose(in: window, title: title, lines: TUIText.plain(message, width: 52),
                                  choices: [Choice(title: cancel, kind: .normal),
                                            Choice(title: confirm, kind: .destructive)],
                                  selected: 1, cancelIndex: 0, promptId: promptId, theme: theme)
        return answer.map { $0 == 1 }
    }

    /// Asks for a line of text in `window` -- `label` above the field,
    /// `hint` below it, `value` in it to start with -- and answers what was
    /// typed when `confirm` is pressed or return typed, nil when cancelled.
    static func askText(in window: NSWindow, title: String, label: String, value: String, hint: String?,
                        confirm: String, cancel: String = "Cancel",
                        promptId: String? = nil,
                        theme: TerminalTheme?) async -> String? {
        guard let content = window.contentView else { return nil }
        var lines = [TUIText.Line(runs: [TUIText.Run(text: label, kind: .muted)]), TUIText.Line(runs: [])]
        if let hint { lines.append(TUIText.Line(runs: [TUIText.Run(text: hint, kind: .muted)])) }
        let view = TerminalDialogView(title: title, lines: lines,
                                      choices: [Choice(title: cancel, kind: .normal), Choice(title: confirm, kind: .primary)],
                                      cancelIndex: 0, style: .from(theme))
        view.promptId = promptId
        view.selected = 1
        view.updateSelection()
        let field = NSTextField(string: value)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = TakoTUI.field
        field.textColor = TakoTUI.bright
        field.font = view.style.font
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = view
        field.setAccessibilityLabel(label)
        view.field = field
        view.fieldRow = 1
        view.addSubview(field)
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        let answer: Int = await withCheckedContinuation { continuation in
            view.finish = { continuation.resume(returning: $0) }
            view.previousResponder = window.firstResponder
            content.addSubview(view, positioned: .above, relativeTo: nil)
            view.layoutSubtreeIfNeeded()
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return answer == 1 ? field.stringValue : nil
    }

    // Return confirms, escape cancels, tab moves between the buttons -- from
    // inside the field, as from the card.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        // The button shown as chosen -- Save until tab moves the choice.
        case #selector(NSResponder.insertNewline(_:)): answer(selected)
        case #selector(NSResponder.cancelOperation(_:)): answer(cancelIndex)
        case #selector(NSResponder.insertTab(_:)): move(1)
        default: return false
        }
        return true
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        // The caret as the terminal's: an Ember block's colour.
        (field?.currentEditor() as? NSTextView)?.insertionPointColor = TakoTUI.ember
    }
}
