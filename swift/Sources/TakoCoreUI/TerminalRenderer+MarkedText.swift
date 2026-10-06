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
    struct MarkedTextLayout: Equatable {
        struct Glyph: Equatable {
            let text: String
            let row: Int
            let col: Int
            let cells: Int
        }

        struct Line: Equatable {
            let row: Int
            let cellRange: Range<Int>
        }

        let glyphs: [Glyph]
        let lines: [Line]
    }

    /// Place a transient IME preedit in terminal cells.
    func markedTextLayout(
        _ text: String,
        cursorCol: Int,
        cols: Int,
        availableRows: Int
    ) -> MarkedTextLayout {
        guard cols > 0, availableRows > 0, !text.isEmpty else {
            return MarkedTextLayout(glyphs: [], lines: [])
        }

        let style = Style(foreground: defaultForeground)
        let source = text.map { character -> (text: String, cells: Int) in
            let grapheme = String(character)
            let measured = CGFloat(CTLineGetTypographicBounds(
                makeLine(grapheme, style: style), nil, nil, nil
            ))
            let cells = min(measured > metrics.cellWidth * 1.25 ? 2 : 1, cols)
            return (grapheme, cells)
        }
        let origin = min(max(cursorCol, 0), cols - 1)

        var logicalRow = 0
        var col = origin
        var positioned: [MarkedTextLayout.Glyph] = []
        positioned.reserveCapacity(source.count)
        for item in source {
            if col + item.cells > cols {
                logicalRow += 1
                col = 0
            }
            positioned.append(.init(
                text: item.text,
                row: logicalRow,
                col: col,
                cells: item.cells
            ))
            col += item.cells
        }

        guard let lastRow = positioned.last?.row else {
            return MarkedTextLayout(glyphs: [], lines: [])
        }
        let firstVisibleRow = max(0, lastRow - availableRows + 1)
        let glyphs = positioned.compactMap { glyph -> MarkedTextLayout.Glyph? in
            guard glyph.row >= firstVisibleRow else { return nil }
            return .init(
                text: glyph.text,
                row: glyph.row - firstVisibleRow,
                col: glyph.col,
                cells: glyph.cells
            )
        }

        var lines: [MarkedTextLayout.Line] = []
        for glyph in glyphs {
            let upperBound = glyph.col + glyph.cells
            if let last = lines.last, last.row == glyph.row {
                lines[lines.count - 1] = .init(
                    row: last.row,
                    cellRange: last.cellRange.lowerBound..<max(last.cellRange.upperBound, upperBound)
                )
            } else {
                lines.append(.init(row: glyph.row, cellRange: glyph.col..<upperBound))
            }
        }
        return MarkedTextLayout(glyphs: glyphs, lines: lines)
    }

    /// Draw in-progress IME composition using the same cell baseline and
    /// fitted glyph placement as committed terminal text. The ordinary
    /// terminal cursor is hidden by the host while this is present.
    public func drawMarkedText(
        _ text: String,
        cursorCol: Int,
        cols: Int,
        availableRows: Int,
        y: CGFloat,
        in context: CGContext
    ) {
        let layout = markedTextLayout(
            text,
            cursorCol: cursorCol,
            cols: cols,
            availableRows: availableRows
        )
        guard !layout.glyphs.isEmpty else { return }

        context.setFillColor(defaultBackground)
        for line in layout.lines {
            let lineY = y - CGFloat(line.row) * metrics.cellHeight
            let x = CGFloat(line.cellRange.lowerBound) * metrics.cellWidth
            let width = CGFloat(line.cellRange.count) * metrics.cellWidth
            context.fill(CGRect(x: x, y: lineY, width: width, height: metrics.cellHeight))
        }

        let style = Style(foreground: defaultForeground)
        for glyph in layout.glyphs {
            let baseline = y
                - CGFloat(glyph.row) * metrics.cellHeight
                + metrics.baseline
            drawFitted(
                glyph.text,
                style: style,
                col: glyph.col,
                cells: glyph.cells,
                baseline: baseline,
                in: context
            )
        }
        for line in layout.lines {
            let lineY = y - CGFloat(line.row) * metrics.cellHeight
            let x = CGFloat(line.cellRange.lowerBound) * metrics.cellWidth
            let width = CGFloat(line.cellRange.count) * metrics.cellWidth
            drawUnderline(
                style: 1,
                color: defaultForeground,
                x: x,
                y: lineY,
                width: width,
                in: context
            )
        }
    }
}
