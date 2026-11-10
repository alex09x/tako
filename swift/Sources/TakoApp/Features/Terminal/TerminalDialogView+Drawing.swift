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
    // MARK: - Look

    /// The shell's colours (`app-appearance`), so a question looks like the
    /// other desktop sheets in light and in dark.
    enum Palette {
        static var card: NSColor { Tako.LivingTokens.surfaceActive }
        static var hairline: NSColor { Tako.LivingTokens.ghostBorder }
        static var title: NSColor { Tako.LivingTokens.text }
        static var body: NSColor { Tako.LivingTokens.textInactive }
        static var muted: NSColor { Tako.LivingTokens.faint }
        static var field: NSColor { Tako.LivingTokens.body }
        static var button: NSColor { Tako.LivingTokens.badge }
    }

    static let cardRadius: CGFloat = 12
    static let padding: CGFloat = 20
    static let iconSize: CGFloat = 28
    /// Where the title and the body start: past the icon tile.
    static let textInset: CGFloat = padding + iconSize + 12
    static let topInset: CGFloat = 18
    static let buttonHeight: CGFloat = 28
    static let minimumWidth: CGFloat = 440
    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let boldFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let hintFont = NSFont.systemFont(ofSize: 11)
    static let buttonFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    // MARK: - Layout

    /// The height of one body row, in the interface font.
    var cellHeight: CGFloat { ceil(Self.bodyFont.ascender - Self.bodyFont.descender + Self.bodyFont.leading) + 4 }

    /// Code keeps the terminal's font, a point smaller than the text around it.
    var codeFont: NSFont { NSFont(descriptor: style.font.fontDescriptor, size: 12) ?? style.font }

    private func attributes(_ kind: TUIText.Run.Kind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .plain: [.font: Self.bodyFont, .foregroundColor: Palette.body]
        case .bold: [.font: Self.boldFont, .foregroundColor: Palette.title]
        case .heading: [.font: Self.boldFont, .foregroundColor: TakoTUI.claw]
        case .bullet: [.font: Self.bodyFont, .foregroundColor: TakoTUI.ember]
        case .muted: [.font: Self.bodyFont, .foregroundColor: Palette.muted]
        case .code: [.font: codeFont, .foregroundColor: Palette.title]
        case .link: [.font: Self.bodyFont, .foregroundColor: TakoTUI.claw,
                     .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
    }

    private func width(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private var spaceWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: Self.bodyFont]).width }

    private func width(of line: TUIText.Line) -> CGFloat {
        CGFloat(line.indent) * spaceWidth + line.runs.reduce(0) { $0 + width($1.text, attributes($1.kind)) }
    }

    func buttonWidth(_ button: DialogButton) -> CGFloat {
        max(width(button.title, [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]) + 28, 72)
    }

    private var buttonsWidth: CGFloat {
        buttons.reduce(0) { $0 + buttonWidth($1) } + CGFloat(max(buttons.count - 1, 0)) * 8
    }

    /// Body lines that fit: no more than `maxBodyRows`, nor than the window holds.
    var visibleRows: Int {
        let chrome = Self.topInset + Self.iconSize + 6 + 14 + Self.buttonHeight + 16
        let fit = Int((bounds.height - chrome - 32) / cellHeight)
        return max(1, min(lines.count, Self.maxBodyRows, max(fit, 3)))
    }

    var maxOffset: Int { max(lines.count - visibleRows, 0) }

    /// The card, in the middle of the window: as wide as its longest line,
    /// its title or its buttons with the hint ask for, never narrower than
    /// the other sheets' cards.
    var cardRect: NSRect {
        let body = lines.map(width(of:)).max() ?? 0
        let needed = [
            Self.textInset + body + Self.padding + (maxOffset > 0 ? 8 : 0),
            Self.textInset + width(title, [.font: Self.titleFont]) + Self.padding,
            Self.padding * 2 + buttonsWidth,
            Self.minimumWidth,
        ].max() ?? Self.minimumWidth
        let cardWidth = min(needed, max(bounds.width - 32, 240))
        let cardHeight = Self.topInset + Self.iconSize + 6 + CGFloat(visibleRows) * cellHeight
            + 14 + Self.buttonHeight + 16
        return NSRect(x: floor((bounds.width - cardWidth) / 2), y: max(floor((bounds.height - cardHeight) / 2), 0),
                      width: cardWidth, height: cardHeight)
    }

    /// The top-left of body row `row` (0 is the first visible one).
    func bodyOrigin(row: Int) -> NSPoint {
        let card = cardRect
        return NSPoint(x: card.minX + Self.textInset,
                       y: card.minY + Self.topInset + Self.iconSize + 6 + CGFloat(row) * cellHeight)
    }

    private var buttonRowY: CGFloat { cardRect.maxY - 16 - Self.buttonHeight }

    override func layout() {
        super.layout()
        // Right-aligned on the last row, the action outermost.
        var right = cardRect.maxX - Self.padding
        for button in buttons.reversed() {
            let buttonWidth = buttonWidth(button)
            button.frame = NSRect(x: right - buttonWidth, y: buttonRowY, width: buttonWidth, height: Self.buttonHeight)
            right -= buttonWidth + 8
        }
        if let field {
            let origin = bodyOrigin(row: fieldRow - offset)
            field.frame = NSRect(x: origin.x, y: origin.y - 1,
                                 width: cardRect.maxX - Self.padding - origin.x, height: cellHeight + 2)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The card of the desktop sheets (Settings, Set Up Tako): a rounded
        // panel in the shell's colours with a hairline and a soft shadow.
        let card = cardRect
        let panel = NSBezierPath(roundedRect: card, xRadius: Self.cardRadius, yRadius: Self.cardRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        Palette.card.setFill()
        panel.fill()
        NSGraphicsContext.restoreGraphicsState()
        Palette.hairline.setStroke()
        let edge = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Self.cardRadius, yRadius: Self.cardRadius)
        edge.lineWidth = 1
        edge.stroke()

        // The icon tile: red for a destructive question, Claw otherwise.
        let destructive = buttons.contains(where: \.isDestructive)
        let tint = destructive ? TakoTUI.danger : TakoTUI.claw
        let tile = NSRect(x: card.minX + Self.padding, y: card.minY + Self.topInset,
                          width: Self.iconSize, height: Self.iconSize)
        tint.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8).fill()
        let glyph = destructive ? "!" : (buttons.count > 1 ? "?" : "i")
        let glyphAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold),
                                                              .foregroundColor: tint]
        let glyphSize = (glyph as NSString).size(withAttributes: glyphAttributes)
        (glyph as NSString).draw(at: NSPoint(x: tile.midX - glyphSize.width / 2, y: tile.midY - glyphSize.height / 2),
                                 withAttributes: glyphAttributes)

        // The title beside it, in the interface font.
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: Palette.title]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        (title as NSString).draw(at: NSPoint(x: card.minX + Self.textInset, y: tile.midY - titleSize.height / 2),
                                 withAttributes: titleAttributes)

        offset = min(offset, maxOffset)
        for (index, line) in lines[offset..<min(offset + visibleRows, lines.count)].enumerated() {
            let origin = bodyOrigin(row: index)
            var x = origin.x + CGFloat(line.indent) * spaceWidth
            for run in line.runs {
                x += draw(run, at: NSPoint(x: x, y: origin.y))
            }
        }
        // Where the view is in a body that scrolls: a thumb on the right edge.
        if maxOffset > 0 {
            let track = NSRect(x: card.maxX - 10, y: bodyOrigin(row: 0).y,
                               width: 3, height: CGFloat(visibleRows) * cellHeight)
            let thumbHeight = max(track.height * CGFloat(visibleRows) / CGFloat(lines.count), cellHeight)
            let thumbY = track.minY + (track.height - thumbHeight) * CGFloat(offset) / CGFloat(maxOffset)
            Palette.hairline.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: thumbY, width: track.width, height: thumbHeight),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        // The keys, quietly, left of the buttons; cut where the buttons begin.
        let hintAttributes: [NSAttributedString.Key: Any] = [.font: Self.hintFont, .foregroundColor: Palette.muted]
        let hintSize = (hint as NSString).size(withAttributes: hintAttributes)
        let room = card.width - Self.padding * 2 - buttonsWidth - 12
        if room > 40 {
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: card.minX + Self.padding, y: buttonRowY, width: room, height: Self.buttonHeight).clip()
            (hint as NSString).draw(at: NSPoint(x: card.minX + Self.padding,
                                                y: buttonRowY + (Self.buttonHeight - hintSize.height) / 2),
                                    withAttributes: hintAttributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Draws `run` at `point` on its row and returns how far it advanced.
    private func draw(_ run: TUIText.Run, at point: NSPoint) -> CGFloat {
        let attributes = attributes(run.kind)
        let size = (run.text as NSString).size(withAttributes: attributes)
        let advance = ceil(size.width)
        if run.kind == .code {
            Palette.field.setFill()
            NSBezierPath(roundedRect: NSRect(x: point.x - 2, y: point.y + 1, width: advance + 4, height: cellHeight - 2),
                         xRadius: 4, yRadius: 4).fill()
        }
        (run.text as NSString).draw(at: NSPoint(x: point.x, y: point.y + (cellHeight - size.height) / 2),
                                    withAttributes: attributes)
        return advance
    }
}
