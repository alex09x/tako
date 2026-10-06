/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import CoreText
import Foundation

extension TerminalRenderer {
    /// Everything that must match for two cells to shape as one run.
    struct Style: Equatable {
        var fg: CGColor
        let bold: Bool
        let italic: Bool
        let underline: Bool
        let underlineStyle: UInt8
        let ul: CGColor
        let strikethrough: Bool
        let overline: Bool
        let hidden: Bool

        init(_ cell: TerminalCell) {
            let (r, g, b) = cell.reverse
                ? (cell.bgR, cell.bgG, cell.bgB)
                : (cell.fgR, cell.fgG, cell.fgB)
            let alpha: CGFloat = cell.hidden ? 0 : (cell.dim ? 0.55 : 1)
            fg = srgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, alpha)
            bold = cell.bold
            italic = cell.italic
            underline = cell.underline
            underlineStyle = cell.underlineStyle
            ul = srgb(CGFloat(cell.ulR) / 255, CGFloat(cell.ulG) / 255, CGFloat(cell.ulB) / 255, 1)
            strikethrough = cell.strikethrough
            overline = cell.overline
            hidden = cell.hidden
        }

        init(foreground: CGColor) {
            fg = foreground
            bold = false
            italic = false
            underline = false
            underlineStyle = 0
            ul = foreground
            strikethrough = false
            overline = false
            hidden = false
        }

        var hasDecoration: Bool { underline || strikethrough || overline }
    }

    /// `Style(cell)`, with the selection override for `col` applied on top.
    func effectiveStyle(_ cell: TerminalCell, col: Int, selectedColumns: ClosedRange<Int>?) -> Style {
        var style = Style(cell)
        guard let selectedColumns, selectedColumns.contains(col) else { return style }
        if selectionInvertFgBg {
            let (r, g, b) = cell.reverse
                ? (cell.fgR, cell.fgG, cell.fgB)
                : (cell.bgR, cell.bgG, cell.bgB)
            style.fg = srgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, cell.hidden ? 0 : 1)
        } else if let selectionForeground {
            style.fg = selectionForeground
        }
        return style
    }

    /// The selected column span within `row`, or nil when `row` is not part of `selection`.
    static func selectedColumnRange(
        for row: Int, selection: FfiSelectionRange, cols: Int
    ) -> ClosedRange<Int>? {
        let r1 = Int(selection.startRow)
        let r2 = Int(selection.endRow)
        let startRow = min(r1, r2)
        let endRow = max(r1, r2)
        guard row >= startRow, row <= endRow else { return nil }
        let first: Int
        let last: Int
        switch selection.mode {
        case .linear:
            first = row == startRow ? Int(selection.startCol) : 0
            last = row == endRow ? Int(selection.endCol) : cols - 1
        case .rectangular:
            let c1 = Int(selection.startCol)
            let c2 = Int(selection.endCol)
            first = min(c1, c2)
            last = max(c1, c2)
        }
        guard last >= first else { return nil }
        return first...last
    }

    func drawRun(
        _ text: String,
        glyphs: [(col: Int, ch: String, wide: Bool)],
        startCol: Int,
        endCol: Int,
        y: CGFloat,
        style: Style,
        in context: CGContext
    ) {
        let x = CGFloat(startCol) * metrics.cellWidth
        let width = CGFloat(endCol - startCol) * metrics.cellWidth

        if !text.isEmpty, !style.hidden {
            let baseline = y + metrics.baseline
            let line = makeLine(text, style: style)
            let measured = CTLineGetTypographicBounds(line, nil, nil, nil)
            let expected = glyphs.reduce(0.0) { $0 + ($1.wide ? 2 : 1) * Double(metrics.cellWidth) }
            if abs(measured - expected) < 0.5 {
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, context)
            } else {
                for glyph in glyphs {
                    drawFitted(glyph.ch, style: style,
                               col: glyph.col, cells: glyph.wide ? 2 : 1,
                               baseline: baseline, in: context)
                }
            }
        }

        if style.underline || style.underlineStyle > 0 {
            drawUnderline(
                style: style.underlineStyle,
                color: style.ul,
                x: x, y: y, width: width,
                in: context
            )
        }
        if style.strikethrough {
            context.setFillColor(style.fg)
            context.fill(CGRect(x: x, y: y + metrics.cellHeight / 2, width: width, height: 1))
        }
        if style.overline {
            context.setFillColor(style.fg)
            context.fill(CGRect(x: x, y: y + metrics.cellHeight - 1, width: width, height: 1))
        }
    }

    /// SGR 4:x underline styles: single, double, curly, dotted, dashed.
    func drawUnderline(
        style: UInt8,
        color: CGColor,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        in context: CGContext
    ) {
        let thickness = metrics.underlineThickness
        let base = y + metrics.cellHeight - metrics.underlinePosition - thickness
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(thickness)
        switch style {
        case 2:
            context.fill(CGRect(x: x, y: base, width: width, height: thickness))
            context.fill(CGRect(x: x, y: base - 3 * thickness, width: width, height: thickness))
        case 3:
            let period = metrics.cellWidth / 2
            let amplitude: CGFloat = 1.5
            context.beginPath()
            context.move(to: CGPoint(x: x, y: base))
            var px = x
            var up = true
            while px < x + width {
                let next = min(px + period, x + width)
                context.addQuadCurve(
                    to: CGPoint(x: next, y: base),
                    control: CGPoint(x: (px + next) / 2, y: base + (up ? amplitude : -amplitude))
                )
                px = next
                up.toggle()
            }
            context.strokePath()
        case 4:
            var px = x
            while px < x + width {
                context.fill(CGRect(x: px, y: base, width: thickness, height: thickness))
                px += 2 * thickness
            }
        case 5:
            var px = x
            while px < x + width {
                context.fill(CGRect(x: px, y: base, width: 4, height: thickness))
                px += 7
            }
        default:
            context.fill(CGRect(x: x, y: base, width: width, height: thickness))
        }
    }

    private func mustFillCell(_ ch: String) -> Bool {
        guard let scalar = ch.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x2500...0x259F,   // box drawing and block elements
             0x25A0...0x25A1,   // filled and hollow squares
             0xE0B0...0xE0D4:   // powerline separators
            return true
        default:
            return false
        }
    }

    func drawFitted(
        _ ch: String,
        style: Style,
        col: Int,
        cells: Int,
        baseline: CGFloat,
        in context: CGContext
    ) {
        let span = CGFloat(cells) * metrics.cellWidth
        let line = makeLine(ch, style: style)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = CGFloat(col) * metrics.cellWidth
        guard width > 0.01 else { return }

        if abs(width - span) < 0.5 {
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            return
        }

        guard mustFillCell(ch) else {
            context.textPosition = CGPoint(x: x + max((span - width) / 2, 0), y: baseline)
            CTLineDraw(line, context)
            return
        }

        context.saveGState()
        context.translateBy(x: x, y: 0)
        context.scaleBy(x: span / width, y: 1)
        context.textPosition = CGPoint(x: 0, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    func makeLine(_ text: String, style: Style) -> CTLine {
        let face = metrics.face(bold: style.bold, italic: style.italic)
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: face.font,
            kCTForegroundColorAttributeName: style.fg,
        ]
        if face.emboldened {
            let width = GlyphAtlas.syntheticBoldStrokeWidth(fontSize: CTFontGetSize(face.font))
            attributes[kCTStrokeWidthAttributeName] = -100 * width / CTFontGetSize(face.font)
            attributes[kCTStrokeColorAttributeName] = style.fg
        }
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attributes as CFDictionary
        )!
        return CTLineCreateWithAttributedString(attributed)
    }
}
