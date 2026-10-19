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

/// A question drawn inside the terminal window instead of a macOS sheet or
/// alert, the way a terminal UI draws one: the terminal dims, and a card on
/// the cell grid, in the terminal's font, asks it --
///
///     ╭─ Close Terminal? ╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╮
///     │                                                 │
///     │  The terminal still has a running process.      │
///     │                                                 │
///     │                             Cancel   ▌ Close ▐  │
///     │                                                 │
///     │  tab choose · return confirm · esc cancel       │
///     ╰─────────────────────────────────────────────────╯
///
/// In the TakoCore palette (`TakoTUI`): the frame and the hatching after the
/// title run from Rust to Ember, the title is Claw. The body is lines of
/// styled runs -- plain text, or release notes with headings, bullets, bold,
/// code and links. The keyboard answers it -- left, right or tab to choose,
/// return to press the chosen button, escape or `n` to cancel, `y` to press
/// the first -- and so does the mouse. Its buttons are real buttons, so
/// VoiceOver and accessibility clients press them like any other.
@MainActor
final class TerminalDialogView: NSView, NSTextFieldDelegate {
    struct Style {
        var font: NSFont
        var background: NSColor
        var foreground: NSColor
        /// Where the border's colour starts.
        var accent: NSColor
        /// Where the border's colour ends.
        var accentEnd: NSColor
        /// Hints.
        var muted: NSColor

        /// The brand palette (see `TakoTUI`), the terminal's font.
        static func from(_ theme: TerminalTheme?) -> Style {
            Style(font: TakoTUI.font(theme), background: TakoTUI.ink, foreground: TakoTUI.text,
                  accent: TakoTUI.rust, accentEnd: TakoTUI.ember, muted: TakoTUI.dim)
        }
    }

    /// A button: its label and how it is filled when chosen.
    struct Choice {
        enum Kind { case destructive, primary, normal }
        var title: String
        var kind: Kind
    }

    static let maxBodyRows = 18

    let style: Style
    let title: String
    let lines: [TUIText.Line]
    let hint: String
    let cancelIndex: Int
    var buttons: [DialogButton] = []
    var selected = 0
    /// The first body line shown, when the body is taller than the card.
    var offset = 0
    private var scrollRemainder: CGFloat = 0
    var finish: ((Int) -> Void)?
    weak var previousResponder: NSResponder?
    private var windowObserver: NSObjectProtocol?
    /// A line to type into, on body row `fieldRow`, when the question asks
    /// for text; return presses the chosen button.
    var field: NSTextField?
    var fieldRow = 0
    /// Associated prompt ID, when presented on behalf of PromptManager (B10).
    var promptId: String?

    /// The question drawn in `window`, if one is waiting for an answer.
    static func pending(in window: NSWindow?) -> TerminalDialogView? {
        window?.contentView?.subviews.lazy.compactMap { $0 as? TerminalDialogView }.first
    }

    /// The question with matching prompt ID drawn in `window`.
    static func pending(in window: NSWindow?, for promptId: String) -> TerminalDialogView? {
        window?.contentView?.subviews.lazy.compactMap { $0 as? TerminalDialogView }.first { $0.promptId == promptId }
    }

    /// Takes the question back unanswered: the same as cancelling it.
    func withdraw() { answer(cancelIndex) }

    /// The question as `takoctl dialog` shows it: title, body text, buttons
    /// and the one chosen.
    var summary: [String: JSON] {
        [
            "title": .string(title),
            "text": .string(lines.map { line in
                String(repeating: " ", count: line.indent) + line.runs.map(\.text).joined()
            }.joined(separator: "\n")),
            "buttons": .array(buttons.map { .string($0.title) }),
            "selected": .string(buttons[selected].title),
        ]
    }

    /// Presses the button titled `title` (case-insensitive), as a click
    /// would. False when there is no such button.
    func press(_ title: String) -> Bool {
        guard let index = buttons.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })
        else { return false }
        answer(index)
        return true
    }

    init(title: String, lines: [TUIText.Line], choices: [Choice], cancelIndex: Int, style: Style) {
        self.style = style
        self.title = title
        self.lines = lines
        self.cancelIndex = cancelIndex
        self.hint = (lines.count > Self.maxBodyRows ? "↑↓ scroll · " : "")
            + (choices.count > 1 ? "tab choose · return confirm · esc cancel" : "return or esc to close")
        super.init(frame: .zero)
        wantsLayer = true
        // The terminal behind dims, as a TUI's backdrop does.
        layer?.backgroundColor = TakoTUI.deep.withAlphaComponent(0.62).cgColor
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("terminal-dialog-view")
        setAccessibilityLabel(title)
        setAccessibilityTitle(title)
        let bodyText = lines.map { line in
            String(repeating: " ", count: line.indent) + line.runs.map(\.text).joined()
        }.joined(separator: "\n")
        setAccessibilityValue(bodyText)

        let promptText = title.isEmpty ? bodyText : "\(title)\n\(bodyText)"
        let textElement = NSTextField(labelWithString: promptText)
        textElement.textColor = .clear
        textElement.drawsBackground = false
        textElement.isBordered = false
        textElement.isEditable = false
        textElement.isSelectable = false
        textElement.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        textElement.setAccessibilityRole(.staticText)
        textElement.setAccessibilityIdentifier("terminal-dialog-body")
        textElement.setAccessibilityLabel(title)
        textElement.setAccessibilityValue(promptText)
        addSubview(textElement)

        buttons = choices.enumerated().map { index, choice in
            let button = DialogButton(choice: choice, style: style)
            button.target = self
            button.action = #selector(pressed(_:))
            button.tag = index
            return button
        }
        buttons.forEach(addSubview)
        updateSelection()
    }

    override func accessibilityChildren() -> [Any]? {
        subviews
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Asks in `window` and answers the index of the button pressed --
    /// `cancelIndex` for escape or a withdrawn question. Nil when the window
    /// has no content view to draw in.
    static func choose(in window: NSWindow, title: String, lines: [TUIText.Line], choices: [Choice],
                       selected: Int = 0, cancelIndex: Int,
                       promptId: String? = nil,
                       theme: TerminalTheme?) async -> Int? {
        guard let content = window.contentView, !choices.isEmpty else { return nil }
        let view = TerminalDialogView(title: title, lines: lines, choices: choices,
                                      cancelIndex: cancelIndex, style: .from(theme))
        view.promptId = promptId
        view.selected = min(max(selected, 0), choices.count - 1)
        view.updateSelection()
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        return await withCheckedContinuation { continuation in
            view.finish = { continuation.resume(returning: $0) }
            view.previousResponder = window.firstResponder
            content.addSubview(view, positioned: .above, relativeTo: nil)
            window.makeFirstResponder(view)
            view.needsLayout = true
        }
    }

    // MARK: - Window & Superview Lifecycle

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.cancelDueToWindowClose()
                }
            }
        } else if finish != nil {
            answer(cancelIndex)
        }
    }

    @MainActor
    private func cancelDueToWindowClose() {
        guard finish != nil else { return }
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }
        answer(cancelIndex)
    }

    override func removeFromSuperview() {
        let pending = self.finish
        self.finish = nil
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }
        let window = self.window
        super.removeFromSuperview()
        // The tab strip under it clears the titlebar's background and redraws
        // on key and main changes; a question answered in a window that was
        // never key -- one restored in the background -- left it hidden until
        // the window was clicked.
        if let window, let bar = Tako.TabBarController.bar(for: window) {
            Tako.TabBarController.clearTitlebarBackground(in: window)
            bar.needsDisplay = true
        }
        pending?(cancelIndex)
    }

    deinit {
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: answering

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: scroll(by: -1)               // up
        case 125: scroll(by: 1)                // down
        case 116: scroll(by: -visibleRows)     // page up
        case 121: scroll(by: visibleRows)      // page down
        case 115: scroll(by: -lines.count)     // home
        case 119: scroll(by: lines.count)      // end
        case 123: move(-1)                     // left
        case 124, 48: move(1)                  // right, tab
        case 36, 76: answer(selected)          // return, keypad enter
        case 53: answer(cancelIndex)           // escape
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "y": answer(buttons.firstIndex { $0.isConfirm } ?? 0)
            case "n": answer(cancelIndex)
            default: break
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Precise deltas (trackpads) come in points, others in lines.
        scrollRemainder -= event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY
        let whole = Int(scrollRemainder)
        guard whole != 0 else { return }
        scrollRemainder -= CGFloat(whole)
        scroll(by: whole)
    }

    private func scroll(by lines: Int) {
        let next = min(max(offset + lines, 0), maxOffset)
        guard next != offset else { return }
        offset = next
        needsDisplay = true
    }

    /// The first body line shown; for tests.
    var scrollOffset: Int { offset }

    /// Clicks outside the card do nothing: modal backdrop blocks underlying terminal.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}; override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}; override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}; override func otherMouseUp(with event: NSEvent) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.isEmpty else { return false }
        if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "w" { withdraw(); return true }
        return true
    }

    func move(_ step: Int) {
        selected = (selected + step + buttons.count) % buttons.count
        updateSelection()
    }

    func updateSelection() {
        for (index, button) in buttons.enumerated() { button.isChosen = index == selected }
    }

    @objc private func pressed(_ sender: NSButton) { answer(sender.tag) }

    func answer(_ index: Int) {
        guard let finish else { return }
        self.finish = nil
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }
        if let field {
            _ = field.validateEditing()
            if let editor = field.currentEditor() as? NSTextView {
                field.stringValue = editor.string
            }
        }
        let window = self.window
        removeFromSuperview()
        if let previousResponder, window?.firstResponder == nil || window?.firstResponder === window {
            window?.makeFirstResponder(previousResponder)
        }
        finish(index)
    }
}
