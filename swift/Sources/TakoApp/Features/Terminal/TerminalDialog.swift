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

    fileprivate let style: Style
    private let title: String
    private let lines: [TUIText.Line]
    private let hint: String
    private let cancelIndex: Int
    private var buttons: [DialogButton] = []
    private var selected = 0
    /// The first body line shown, when the body is taller than the card.
    private var offset = 0
    private var scrollRemainder: CGFloat = 0
    private var finish: ((Int) -> Void)?
    private weak var previousResponder: NSResponder?
    /// A line to type into, on body row `fieldRow`, when the question asks
    /// for text; return presses `fieldConfirm`.
    private var field: NSTextField?
    private var fieldRow = 0
    private var fieldConfirm = 0

    /// The question drawn in `window`, if one is waiting for an answer.
    static func pending(in window: NSWindow?) -> TerminalDialogView? {
        window?.contentView?.subviews.lazy.compactMap { $0 as? TerminalDialogView }.first
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

    private init(title: String, lines: [TUIText.Line], choices: [Choice], cancelIndex: Int, style: Style) {
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Asks in `window` and answers whether the user confirmed: `confirm`
    /// (destructive) or `cancel`. Nil when the window has no content view.
    static func ask(in window: NSWindow, title: String, message: String,
                    confirm: String, cancel: String = "Cancel",
                    theme: TerminalTheme?) async -> Bool? {
        // The safe choice is on the left, the confirm on the right and chosen.
        let answer = await choose(in: window, title: title, lines: TUIText.plain(message, width: 52),
                                  choices: [Choice(title: cancel, kind: .normal),
                                            Choice(title: confirm, kind: .destructive)],
                                  selected: 1, cancelIndex: 0, theme: theme)
        return answer.map { $0 == 1 }
    }

    /// Asks for a line of text in `window` -- `label` above the field,
    /// `hint` below it, `value` in it to start with -- and answers what was
    /// typed when `confirm` is pressed or return typed, nil when cancelled.
    static func askText(in window: NSWindow, title: String, label: String, value: String, hint: String?,
                        confirm: String, cancel: String = "Cancel", theme: TerminalTheme?) async -> String? {
        guard let content = window.contentView else { return nil }
        var lines = [TUIText.Line(runs: [TUIText.Run(text: label, kind: .muted)]), TUIText.Line(runs: [])]
        if let hint { lines.append(TUIText.Line(runs: [TUIText.Run(text: hint, kind: .muted)])) }
        let view = TerminalDialogView(title: title, lines: lines,
                                      choices: [Choice(title: cancel, kind: .normal), Choice(title: confirm, kind: .primary)],
                                      cancelIndex: 0, style: .from(theme))
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
        view.fieldConfirm = 1
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
        case #selector(NSResponder.insertNewline(_:)): answer(fieldConfirm)
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

    /// Asks in `window` and answers the index of the button pressed --
    /// `cancelIndex` for escape or a withdrawn question. Nil when the window
    /// has no content view to draw in.
    static func choose(in window: NSWindow, title: String, lines: [TUIText.Line], choices: [Choice],
                       selected: Int = 0, cancelIndex: Int, theme: TerminalTheme?) async -> Int? {
        guard let content = window.contentView, !choices.isEmpty else { return nil }
        let view = TerminalDialogView(title: title, lines: lines, choices: choices,
                                      cancelIndex: cancelIndex, style: .from(theme))
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

    /// Clicks outside the card do nothing: the question stays until answered.
    override func mouseDown(with event: NSEvent) {}

    private func move(_ step: Int) {
        selected = (selected + step + buttons.count) % buttons.count
        updateSelection()
    }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() { button.isChosen = index == selected }
    }

    @objc private func pressed(_ sender: NSButton) { answer(sender.tag) }

    private func answer(_ index: Int) {
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

/// A dialog button drawn in cells, as a terminal UI draws one: the chosen
/// one a filled block -- red for a destructive action, Ember otherwise -- the
/// other on the field colour.
@MainActor
private final class DialogButton: NSButton {
    private let style: TerminalDialogView.Style
    private let kind: TerminalDialogView.Choice.Kind
    var isChosen = false { didSet { needsDisplay = true } }
    var isConfirm: Bool { kind != .normal }

    init(choice: TerminalDialogView.Choice, style: TerminalDialogView.Style) {
        self.style = style
        self.kind = choice.kind
        super.init(frame: .zero)
        self.title = choice.title
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let font: NSFont
        let color: NSColor
        if isChosen {
            (kind == .destructive ? TakoTUI.danger : TakoTUI.ember).setFill()
            font = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
            color = kind == .destructive ? TakoTUI.bright : TakoTUI.deep
        } else {
            TakoTUI.field.setFill()
            font = style.font
            color = TakoTUI.text
        }
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let label = title as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                   withAttributes: attributes)
    }
}

/// Text for a terminal-style card: lines of styled runs, wrapped to a width
/// in cells.
enum TUIText {
    struct Run: Equatable {
        enum Kind { case plain, bold, heading, bullet, code, link, muted }
        var text: String
        var kind: Kind
    }

    struct Line: Equatable {
        var indent = 0
        var runs: [Run]
        var width: Int { indent + runs.reduce(0) { $0 + $1.text.count } }
    }

    /// `text`, wrapped at word boundaries.
    static func plain(_ text: String, width: Int) -> [Line] {
        text.components(separatedBy: "\n").flatMap { wrap([Run(text: $0, kind: .plain)], width: width) }
    }

    /// Release notes in the Markdown GitHub keeps: `##` headings, `-`
    /// bullets, `**bold**`, `` `code` `` and `[links](url)`. At most
    /// `maxLines`, then a line saying where the rest is.
    static func markdown(_ text: String, width: Int, maxLines: Int) -> [Line] {
        var lines: [Line] = []
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let last = lines.last, !last.runs.isEmpty { lines.append(Line(runs: [])) }
            } else if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                lines.append(Line(runs: [Run(text: heading, kind: .heading)]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let body = wrap(inline(String(line.dropFirst(2))), width: width - 2)
                for (index, wrapped) in body.enumerated() {
                    lines.append(index == 0
                        ? Line(runs: [Run(text: "• ", kind: .bullet)] + wrapped.runs)
                        : Line(indent: 2, runs: wrapped.runs))
                }
            } else {
                lines += wrap(inline(line), width: width)
            }
        }
        while lines.last?.runs.isEmpty == true { lines.removeLast() }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines - 1))
            lines.append(Line(runs: [Run(text: "… the full notes are on GitHub", kind: .muted)]))
        }
        return lines
    }

    /// One line of Markdown into runs.
    static func inline(_ text: String) -> [Run] {
        var runs: [Run] = []
        var rest = Substring(text)
        func plain(_ s: Substring) { if !s.isEmpty { runs.append(Run(text: String(s), kind: .plain)) } }
        while !rest.isEmpty {
            if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**") {
                runs.append(Run(text: String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]), kind: .bold))
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("`"), let end = rest.dropFirst().firstIndex(of: "`") {
                runs.append(Run(text: String(rest[rest.index(after: rest.startIndex)..<end]), kind: .code))
                rest = rest[rest.index(after: end)...]
            } else if rest.hasPrefix("["), let close = rest.range(of: "]("),
                      let end = rest[close.upperBound...].firstIndex(of: ")") {
                runs.append(Run(text: String(rest[rest.index(after: rest.startIndex)..<close.lowerBound]), kind: .link))
                rest = rest[rest.index(after: end)...]
            } else {
                let next = rest.dropFirst().firstIndex { "*`[".contains($0) } ?? rest.endIndex
                plain(rest[rest.startIndex..<next])
                rest = rest[next...]
            }
        }
        // Neighbouring plain runs are one run.
        return runs.reduce(into: []) { merged, run in
            if run.kind == .plain, merged.last?.kind == .plain { merged[merged.count - 1].text += run.text } else { merged.append(run) }
        }
    }

    /// Runs wrapped at spaces to `width` cells; a word longer than a line is
    /// split across lines.
    static func wrap(_ runs: [Run], width: Int) -> [Line] {
        var lines: [Line] = []
        var current: [Run] = []
        var used = 0
        func push(_ text: String, _ kind: Run.Kind) {
            if let last = current.last, last.kind == kind { current[current.count - 1].text += text } else { current.append(Run(text: text, kind: kind)) }
            used += text.count
        }
        for run in runs {
            // Words with the space before them, so a line never starts with one.
            var words = run.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if words.isEmpty { words = [""] }
            for (index, word) in words.enumerated() {
                let lead = index > 0 ? " " : ""
                if used > 0, used + lead.count + word.count > width {
                    lines.append(Line(runs: current))
                    current = []
                    used = 0
                } else if used > 0 || !lead.isEmpty {
                    push(lead, run.kind)
                }
                // A word longer than a line goes on in width-sized pieces,
                // each on a line of its own: nothing is dropped.
                var rest = Substring(word)
                while rest.count > max(width - used, 1) {
                    let room = max(width - used, 1)
                    push(String(rest.prefix(room)), run.kind)
                    rest = rest.dropFirst(room)
                    lines.append(Line(runs: current))
                    current = []
                    used = 0
                }
                push(String(rest), run.kind)
            }
        }
        lines.append(Line(runs: current))
        return lines
    }
}
