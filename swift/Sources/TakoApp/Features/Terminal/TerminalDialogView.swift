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

    let style: Style
    private let title: String
    private let lines: [TUIText.Line]
    private let hint: String
    let cancelIndex: Int
    private var buttons: [DialogButton] = []
    var selected = 0
    /// The first body line shown, when the body is taller than the card.
    private var offset = 0
    private var scrollRemainder: CGFloat = 0
    var finish: ((Int) -> Void)?
    weak var previousResponder: NSResponder?
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

    // MARK: the grid

    private var cellHeight: CGFloat { ceil(style.font.ascender - style.font.descender + style.font.leading) }
    /// The font's own advance, not rounded: runs are placed by counting
    /// cells, and a rounded width drifts from where the glyphs actually end.
    private var cellWidth: CGFloat { ("M" as NSString).size(withAttributes: [.font: style.font]).width }
    private var boldFont: NSFont { NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask) }

    private var buttonsWidth: Int { buttons.reduce(0) { $0 + $1.title.count + 4 } + max(buttons.count - 1, 0) }

    /// The card's size in cells: border, blank, body, blank, buttons, blank,
    /// hint, border.
    private var columns: Int {
        let longest = ([title.count + 8, hint.count, buttonsWidth + 2] + lines.map(\.width)).max() ?? 40
        return min(longest + 6, max(Int(bounds.width / cellWidth) - 4, 24))
    }

    /// At most this many body lines show at once; the rest scroll.
    static let maxBodyRows = 18

    /// Body lines that fit: no more than `maxBodyRows`, nor than the window holds.
    private var visibleRows: Int {
        let fit = Int(bounds.height / cellHeight) - 9
        return max(1, min(lines.count, Self.maxBodyRows, max(fit, 3)))
    }

    private var maxOffset: Int { max(lines.count - visibleRows, 0) }

    private var rows: Int { visibleRows + 7 }

    /// The top-left of the cell at `column`, `row` of the card, which sits on
    /// whole cells in the middle of the window.
    private func cell(_ column: Int, _ row: Int) -> NSPoint {
        let left = floor((bounds.width / cellWidth - CGFloat(columns)) / 2) * cellWidth
        let top = max(floor((bounds.height / cellHeight - CGFloat(rows)) / 2), 0) * cellHeight
        return NSPoint(x: left + CGFloat(column) * cellWidth, y: top + CGFloat(row) * cellHeight)
    }

    private var cardRect: NSRect {
        let origin = cell(0, 0)
        return NSRect(x: origin.x, y: origin.y, width: CGFloat(columns) * cellWidth, height: CGFloat(rows) * cellHeight)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // On the buttons row, right-aligned, a cell apart.
        var column = columns - 3
        for button in buttons.reversed() {
            let width = button.title.count + 4
            column -= width
            let origin = cell(column, rows - 4)
            button.frame = NSRect(x: origin.x, y: origin.y, width: CGFloat(width) * cellWidth, height: cellHeight)
            column -= 1
        }
        if let field {
            // The field on its row, the whole width inside the frame's padding.
            let origin = cell(3, 2 + fieldRow - offset)
            field.frame = NSRect(x: origin.x - cellWidth / 2, y: origin.y,
                                 width: CGFloat(columns - 5) * cellWidth, height: cellHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = cardRect
        style.background.setFill()
        card.fill()

        // The colour of column `c`, from one accent to the other across the card.
        let gradient = NSGradient(starting: style.accent, ending: style.accentEnd)
        func shade(_ column: Int) -> NSColor {
            gradient?.interpolatedColor(atLocation: CGFloat(column) / CGFloat(max(columns - 1, 1))) ?? style.accent
        }

        // The frame, drawn as the terminal draws box-drawing characters:
        // lines through the middle of the edge cells, corners rounded by half
        // a cell -- ╭─╮ │ ╰─╯ -- clipped to the shaded gradient.
        let inset = NSRect(x: card.minX + cellWidth / 2, y: card.minY + cellHeight / 2,
                           width: card.width - cellWidth, height: card.height - cellHeight)
        let radius = min(cellWidth, cellHeight) / 2
        let frame = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let stroke = frame.cgPath.copy(strokingWithWidth: 1.25, lineCap: .butt, lineJoin: .round, miterLimit: 1)
        NSBezierPath(cgPath: stroke).addClip()
        gradient?.draw(in: card, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        // The title on a gap in the top border, then hatching to the corner:
        // ╭─ Close Terminal? ╱╱╱╱╱╱╱╱╮
        let titleStart = 2
        let gap = cell(titleStart, 0)
        style.background.setFill()
        NSRect(x: gap.x, y: gap.y, width: CGFloat(columns - titleStart - 2) * cellWidth, height: cellHeight).fill()
        draw(title, column: titleStart + 1, row: 0, font: boldFont, color: TakoTUI.claw)
        let hatchStart = titleStart + title.count + 2
        if hatchStart < columns - 2 {
            for column in hatchStart..<(columns - 2) {
                draw("╱", column: column, row: 0, font: style.font, color: shade(column))
            }
        }

        offset = min(offset, maxOffset)
        for (index, line) in lines[offset..<min(offset + visibleRows, lines.count)].enumerated() {
            var column = 3 + line.indent
            for run in line.runs {
                draw(run, column: column, row: 2 + index)
                column += run.text.count
            }
        }
        // Where the view is in a body that scrolls: a thumb on the right
        // edge of the frame, in Ember.
        if maxOffset > 0 {
            let track = NSRect(x: card.maxX - cellWidth / 2 - 1.5, y: cell(0, 2).y,
                               width: 3, height: CGFloat(visibleRows) * cellHeight)
            let thumbHeight = max(track.height * CGFloat(visibleRows) / CGFloat(lines.count), cellHeight)
            let thumbY = track.minY + (track.height - thumbHeight) * CGFloat(offset) / CGFloat(maxOffset)
            TakoTUI.ember.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: thumbY, width: track.width, height: thumbHeight),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
        draw(hint, column: 3, row: rows - 2, font: style.font, color: style.muted)
    }

    private func draw(_ run: TUIText.Run, column: Int, row: Int) {
        let origin = cell(column, row)
        var attributes: [NSAttributedString.Key: Any]
        switch run.kind {
        case .plain: attributes = [.font: style.font, .foregroundColor: TakoTUI.soft]
        case .bold: attributes = [.font: boldFont, .foregroundColor: TakoTUI.bright]
        case .heading: attributes = [.font: boldFont, .foregroundColor: TakoTUI.claw]
        case .bullet: attributes = [.font: style.font, .foregroundColor: TakoTUI.ember]
        case .muted: attributes = [.font: style.font, .foregroundColor: style.muted]
        case .code:
            TakoTUI.field.setFill()
            NSRect(x: origin.x, y: origin.y, width: CGFloat(run.text.count) * cellWidth, height: cellHeight).fill()
            attributes = [.font: style.font, .foregroundColor: TakoTUI.claw]
        case .link:
            attributes = [.font: style.font, .foregroundColor: TakoTUI.claw,
                          .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
        let height = (run.text as NSString).size(withAttributes: attributes).height
        (run.text as NSString).draw(at: NSPoint(x: origin.x, y: origin.y + (cellHeight - height) / 2),
                                    withAttributes: attributes)
    }

    /// Text placed in its cell as the terminal places glyphs: from the
    /// cell's left edge, centred in its height.
    private func draw(_ text: String, column: Int, row: Int, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let origin = cell(column, row)
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(at: NSPoint(x: origin.x, y: origin.y + (cellHeight - height) / 2),
                                withAttributes: attributes)
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
        let window = self.window
        removeFromSuperview()
        if let previousResponder, window?.firstResponder == nil || window?.firstResponder === window {
            window?.makeFirstResponder(previousResponder)
        }
        finish(index)
    }
}
