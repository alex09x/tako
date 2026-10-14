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
    // MARK: - Layout & Grid Metrics

    var cellHeight: CGFloat { ceil(style.font.ascender - style.font.descender + style.font.leading) }

    /// The font's own advance, not rounded: runs are placed by counting
    /// cells, and a rounded width drifts from where the glyphs actually end.
    var cellWidth: CGFloat { ("M" as NSString).size(withAttributes: [.font: style.font]).width }

    var boldFont: NSFont { NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask) }

    var buttonsWidth: Int { buttons.reduce(0) { $0 + $1.title.count + 4 } + max(buttons.count - 1, 0) }

    /// The card's size in cells: border, blank, body, blank, buttons, blank,
    /// hint, border.
    var columns: Int {
        let longest = ([title.count + 8, hint.count, buttonsWidth + 2] + lines.map(\.width)).max() ?? 40
        return min(longest + 6, max(Int(bounds.width / cellWidth) - 4, 24))
    }

    /// Body lines that fit: no more than `maxBodyRows`, nor than the window holds.
    var visibleRows: Int {
        let fit = Int(bounds.height / cellHeight) - 9
        return max(1, min(lines.count, Self.maxBodyRows, max(fit, 3)))
    }

    var maxOffset: Int { max(lines.count - visibleRows, 0) }

    var rows: Int { visibleRows + 7 }

    /// The top-left of the cell at `column`, `row` of the card, which sits on
    /// whole cells in the middle of the window.
    func cell(_ column: Int, _ row: Int) -> NSPoint {
        let left = floor((bounds.width / cellWidth - CGFloat(columns)) / 2) * cellWidth
        let top = max(floor((bounds.height / cellHeight - CGFloat(rows)) / 2), 0) * cellHeight
        return NSPoint(x: left + CGFloat(column) * cellWidth, y: top + CGFloat(row) * cellHeight)
    }

    var cardRect: NSRect {
        let origin = cell(0, 0)
        return NSRect(x: origin.x, y: origin.y, width: CGFloat(columns) * cellWidth, height: CGFloat(rows) * cellHeight)
    }

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

    // MARK: - Drawing

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

    private func draw(_ text: String, column: Int, row: Int, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let origin = cell(column, row)
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(at: NSPoint(x: origin.x, y: origin.y + (cellHeight - height) / 2),
                                withAttributes: attributes)
    }
}
