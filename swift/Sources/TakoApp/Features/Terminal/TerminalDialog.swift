import AppKit

/// A confirmation drawn inside the terminal window instead of a macOS sheet,
/// the way a terminal UI draws one: the terminal dims, and a card on the cell
/// grid, in the terminal's font and the colours of its theme's palette,
/// asks the question --
///
///     ╭─ Close Terminal? ╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╱╮
///     │                                                 │
///     │  The terminal still has a running process.      │
///     │                                                 │
///     │                            ▌ Close ▐   Cancel   │
///     │                                                 │
///     │  tab choose · return confirm · esc cancel       │
///     ╰─────────────────────────────────────────────────╯
///
/// The border and title run from the palette's magenta to its blue; the
/// chosen button is filled with the magenta. The keyboard answers it -- left,
/// right or tab to choose, return to confirm the chosen button, escape or `n`
/// to cancel, `y` to confirm -- and so does the mouse. Its buttons are real
/// buttons, so VoiceOver and accessibility clients press them like any other.
@MainActor
final class TerminalDialogView: NSView {
    struct Style {
        var font: NSFont
        var background: NSColor
        var foreground: NSColor
        /// Where the border and title's colour starts, and the chosen button's fill.
        var accent: NSColor
        /// Where the border and title's colour ends.
        var accentEnd: NSColor
        /// Hints and the unchosen button's text.
        var muted: NSColor

        static func from(_ theme: TerminalTheme?) -> Style {
            let size = max(theme?.fontSize ?? 13, 11)
            let font = theme?.fontFamily.flatMap { NSFont(name: $0, size: size) }
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let background = theme.flatMap { NSColor(cgColor: $0.background) } ?? .black
            let foreground = theme.flatMap { NSColor(cgColor: $0.foreground) } ?? .white
            // The theme's own palette: bright magenta and bright blue, as a
            // TUI in this terminal would colour itself; a theme without them
            // gets Tako's defaults.
            func palette(_ index: Int, _ fallback: NSColor) -> NSColor {
                theme?.palette[index].flatMap { NSColor(cgColor: $0) } ?? fallback
            }
            return Style(
                font: font, background: background, foreground: foreground,
                accent: palette(13, NSColor(srgbRed: 0.85, green: 0.47, blue: 0.95, alpha: 1)),
                accentEnd: palette(12, NSColor(srgbRed: 0.45, green: 0.62, blue: 1.0, alpha: 1)),
                muted: palette(8, foreground.withAlphaComponent(0.45)))
        }
    }

    private let style: Style
    private let title: String
    private let message: String
    private var buttons: [DialogButton] = []
    private var selected = 0
    private var finish: ((Bool) -> Void)?
    private weak var previousResponder: NSResponder?

    /// The question drawn in `window`, if one is waiting for an answer.
    static func pending(in window: NSWindow?) -> TerminalDialogView? {
        window?.contentView?.subviews.lazy.compactMap { $0 as? TerminalDialogView }.first
    }

    /// Takes the question back unanswered: the same as cancelling it.
    func withdraw() { answer(false) }

    private init(title: String, message: String, confirm: String, cancel: String, style: Style) {
        self.style = style
        self.title = title
        self.message = message
        super.init(frame: .zero)
        wantsLayer = true
        // The terminal behind dims, as a TUI's backdrop does.
        layer?.backgroundColor = style.background.withAlphaComponent(0.75).cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        buttons = [confirm, cancel].enumerated().map { index, label in
            let button = DialogButton(title: label, style: style)
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

    /// Asks in `window` and answers whether the user confirmed. Nil when the
    /// window has no content view to draw in.
    static func ask(in window: NSWindow, title: String, message: String,
                    confirm: String, cancel: String = "Cancel",
                    theme: TerminalTheme?) async -> Bool? {
        guard let content = window.contentView else { return nil }
        let view = TerminalDialogView(title: title, message: message, confirm: confirm,
                                      cancel: cancel, style: .from(theme))
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
    private var cellWidth: CGFloat { ceil(("M" as NSString).size(withAttributes: [.font: style.font]).width) }
    private var boldFont: NSFont { NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask) }

    private let hint = "tab choose · return confirm · esc cancel"

    /// The message, wrapped at word boundaries to a readable width.
    private var messageLines: [String] {
        let width = 52
        var lines: [String] = []
        for paragraph in message.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                if !line.isEmpty, line.count + 1 + word.count > width {
                    lines.append(line)
                    line = String(word)
                } else {
                    line += line.isEmpty ? String(word) : " " + word
                }
            }
            lines.append(line)
        }
        return lines
    }

    /// The card's size in cells: border, blank, message, blank, buttons,
    /// blank, hint, border.
    private var columns: Int {
        let longest = ([title.count + 8, hint.count] + messageLines.map(\.count)).max() ?? 40
        return min(longest + 6, max(Int(bounds.width / cellWidth) - 4, 24))
    }

    private var rows: Int { messageLines.count + 7 }

    /// The top-left of the cell at `column`, `row` of the card, which sits on
    /// whole cells in the middle of the window.
    private func cell(_ column: Int, _ row: Int) -> NSPoint {
        let left = floor((bounds.width / cellWidth - CGFloat(columns)) / 2) * cellWidth
        let top = floor((bounds.height / cellHeight - CGFloat(rows)) / 2) * cellHeight
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
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = cardRect
        style.background.setFill()
        card.fill()

        // The colour of column `c`, from one accent to the other across the
        // card, as Crush shades its borders and titles.
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

        // The title on a gap in the top border, then Crush's hatching to
        // the corner: ╭─ Close Terminal? ╱╱╱╱╱╱╱╱╮
        let titleStart = 2
        let gap = cell(titleStart, 0)
        style.background.setFill()
        NSRect(x: gap.x, y: gap.y, width: CGFloat(columns - titleStart - 2) * cellWidth, height: cellHeight).fill()
        for (offset, character) in title.enumerated() {
            draw(String(character), column: titleStart + 1 + offset, row: 0, font: boldFont,
                 color: shade(titleStart + 1 + offset))
        }
        let hatchStart = titleStart + title.count + 2
        if hatchStart < columns - 2 {
            for column in hatchStart..<(columns - 2) {
                draw("╱", column: column, row: 0, font: style.font, color: shade(column).withAlphaComponent(0.55))
            }
        }

        for (index, line) in messageLines.enumerated() {
            draw(line, column: 3, row: 2 + index, font: style.font, color: style.foreground)
        }
        draw(hint, column: 3, row: rows - 2, font: style.font, color: style.muted)
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
        case 123: move(-1)                     // left
        case 124, 48: move(1)                  // right, tab
        case 36, 76: answer(selected == 0)     // return, keypad enter
        case 53: answer(false)                 // escape
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "y": answer(true)
            case "n": answer(false)
            default: break
            }
        }
    }

    /// Clicks outside the card do nothing: the question stays until answered.
    override func mouseDown(with event: NSEvent) {}

    private func move(_ step: Int) {
        selected = (selected + step + buttons.count) % buttons.count
        updateSelection()
    }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() { button.isChosen = index == selected }
    }

    @objc private func pressed(_ sender: NSButton) { answer(sender.tag == 0) }

    private func answer(_ confirmed: Bool) {
        guard let finish else { return }
        self.finish = nil
        let window = self.window
        removeFromSuperview()
        if let previousResponder, window?.firstResponder == nil || window?.firstResponder === window {
            window?.makeFirstResponder(previousResponder)
        }
        finish(confirmed)
    }
}

/// A dialog button drawn in cells, as a terminal UI draws one: the chosen
/// one a block of the accent with the background's colour for its text, the
/// other a quieter block in the muted colour.
@MainActor
private final class DialogButton: NSButton {
    private let style: TerminalDialogView.Style
    var isChosen = false { didSet { needsDisplay = true } }

    init(title: String, style: TerminalDialogView.Style) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
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
            style.accent.setFill()
            font = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
            color = style.background
        } else {
            (style.background.blended(withFraction: 0.12, of: style.foreground) ?? style.background).setFill()
            font = style.font
            color = style.foreground.withAlphaComponent(0.75)
        }
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let label = title as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                   withAttributes: attributes)
    }
}
