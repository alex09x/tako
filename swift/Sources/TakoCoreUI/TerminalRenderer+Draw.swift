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
import Foundation

extension TerminalRenderer {
    /// Draw a view's grid where `layout` puts it, with its margins filled as
    /// `window-padding-color` says.
    public func drawWindow(
        in context: CGContext,
        windowSize: CGSize,
        layout: TerminalGridLayout,
        paddingColor: TerminalTheme.WindowPaddingColor,
        alternateScreen: Bool = false,
        cols: Int,
        rows: Int,
        rowProvider: (Int) -> [TerminalCell],
        graphemes: [FfiGrapheme] = [],
        cursorRow: Int,
        cursorCol: Int,
        cursorVisible: Bool,
        cursorStyle: FfiCursorStyle,
        selection: FfiSelectionRange? = nil
    ) {
        let gridSize = pixelSize(cols: cols, rows: rows)
        let bottomInset = max(0, windowSize.height - layout.top - gridSize.height)
        if paddingColor != .background, cols > 0, rows > 0 {
            drawMargins(
                in: context,
                windowSize: windowSize,
                left: layout.left,
                bottom: bottomInset,
                cols: cols,
                rows: rows,
                rowProvider: rowProvider,
                always: paddingColor == .extendAlways || alternateScreen
            )
        }
        context.translateBy(x: layout.left, y: bottomInset)
        draw(
            in: context, cols: cols, rows: rows, rowProvider: rowProvider, graphemes: graphemes,
            cursorRow: cursorRow, cursorCol: cursorCol, cursorVisible: cursorVisible,
            cursorStyle: cursorStyle, selection: selection
        )
    }

    private func drawMargins(
        in context: CGContext,
        windowSize: CGSize,
        left: CGFloat,
        bottom: CGFloat,
        cols: Int,
        rows: Int,
        rowProvider: (Int) -> [TerminalCell],
        always: Bool
    ) {
        let gridSize = pixelSize(cols: cols, rows: rows)
        let right = max(0, windowSize.width - left - gridSize.width)
        let top = max(0, windowSize.height - bottom - gridSize.height)
        for row in 0..<rows {
            let cells = rowProvider(row)
            let y = bottom + CGFloat(rows - 1 - row) * metrics.cellHeight
            if left > 0, let color = marginColor(of: cells.first) {
                context.setFillColor(color)
                context.fill(CGRect(x: 0, y: y, width: left, height: metrics.cellHeight))
            }
            if right > 0, let color = marginColor(of: cells.last) {
                context.setFillColor(color)
                context.fill(CGRect(x: left + gridSize.width, y: y, width: right, height: metrics.cellHeight))
            }
        }
        for (row, y, height) in [(0, bottom + gridSize.height, top), (rows - 1, CGFloat(0), bottom)] where height > 0 {
            let cells = rowProvider(row)
            guard always || !cells.contains(where: { marginColor(of: $0) == nil }) else { continue }
            for (col, cell) in cells.prefix(cols).enumerated() {
                guard let color = marginColor(of: cell) else { continue }
                context.setFillColor(color)
                context.fill(CGRect(
                    x: left + CGFloat(col) * metrics.cellWidth, y: y, width: metrics.cellWidth, height: height
                ))
            }
        }
    }

    /// Draw the whole viewport.
    public func draw(
        in context: CGContext,
        cols: Int,
        rows: Int,
        rowProvider: (Int) -> [TerminalCell],
        graphemes: [FfiGrapheme] = [],
        cursorRow: Int,
        cursorCol: Int,
        cursorVisible: Bool,
        cursorStyle: FfiCursorStyle,
        selection: FfiSelectionRange? = nil,
        skipBackgrounds: Bool = false
    ) {
        if !skipBackgrounds {
            let size = pixelSize(cols: cols, rows: rows)
            context.setFillColor(defaultBackground)
            context.fill(CGRect(origin: .zero, size: size))
        }

        if let selection, !selectionInvertFgBg {
            drawSelection(selection, cols: cols, rows: rows, in: context)
        }

        var rowGraphemes: [Int: [Int: String]] = [:]
        for grapheme in graphemes {
            rowGraphemes[Int(grapheme.row), default: [:]][Int(grapheme.col)] = grapheme.text
        }
        for row in 0..<rows {
            let cells = rowProvider(row)
            let selectedColumns = selection.flatMap {
                Self.selectedColumnRange(for: row, selection: $0, cols: cols)
            }
            drawRow(
                cells, row: row, rows: rows, graphemes: rowGraphemes[row] ?? [:], in: context,
                skipBackground: skipBackgrounds, selectedColumns: selectedColumns
            )
        }

        if cursorVisible {
            drawCursor(
                in: context,
                row: cursorRow,
                col: cursorCol,
                rows: rows,
                style: cursorStyle
            )
        }
    }

    public func drawRow(
        _ cells: [TerminalCell], row: Int, rows: Int, graphemes: [Int: String] = [:],
        in context: CGContext, skipBackground: Bool = false,
        selectedColumns: ClosedRange<Int>? = nil
    ) {
        let y = CGFloat(rows - 1 - row) * metrics.cellHeight

        if !skipBackground {
            for run in backgroundRuns(for: cells, selectedColumns: selectedColumns) {
                context.setFillColor(run.color)
                context.fill(CGRect(
                    x: CGFloat(run.range.lowerBound) * metrics.cellWidth,
                    y: y,
                    width: CGFloat(run.range.count) * metrics.cellWidth,
                    height: metrics.cellHeight
                ))
            }
        }

        var index = 0
        while index < cells.count {
            let style = effectiveStyle(cells[index], col: index, selectedColumns: selectedColumns)
            var text = ""
            var glyphs: [(col: Int, ch: String, wide: Bool)] = []
            let startCol = index
            while index < cells.count,
                  effectiveStyle(cells[index], col: index, selectedColumns: selectedColumns) == style {
                let cell = cells[index]
                if cell.ch != 0 {
                    let ch = cell.hasGrapheme
                        ? graphemes[index] ?? Self.string(for: cell.ch)
                        : Self.string(for: cell.ch)
                    text += ch
                    glyphs.append((col: index, ch: ch, wide: cell.wide))
                }
                index += 1
            }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty || style.hasDecoration else {
                continue
            }
            drawRun(
                text,
                glyphs: glyphs,
                startCol: startCol,
                endCol: index,
                y: y,
                style: style,
                in: context
            )
        }
    }

    private func drawSelection(
        _ selection: FfiSelectionRange,
        cols: Int,
        rows: Int,
        in context: CGContext
    ) {
        context.setFillColor(selectionColor)
        let r1 = Int(selection.startRow)
        let r2 = Int(selection.endRow)
        let startRow = min(r1, r2)
        let endRow = max(r1, r2)
        for row in startRow...endRow {
            guard row >= 0, row < rows else { continue }
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
            guard last >= first else { continue }
            let y = CGFloat(rows - 1 - row) * metrics.cellHeight
            context.fill(CGRect(
                x: CGFloat(first) * metrics.cellWidth,
                y: y,
                width: CGFloat(last - first + 1) * metrics.cellWidth,
                height: metrics.cellHeight
            ))
        }
    }

    private func drawCursor(
        in context: CGContext,
        row: Int,
        col: Int,
        rows: Int,
        style: FfiCursorStyle
    ) {
        let x = CGFloat(col) * metrics.cellWidth
        let y = CGFloat(rows - 1 - row) * metrics.cellHeight
        let thickness = cursorThickness ?? 2
        let fillColor = cursorColor.copy(alpha: CGFloat(cursorOpacity)) ?? cursorColor
        context.setFillColor(fillColor)
        switch style.shape {
        case .block:
            let cell = CGRect(x: x, y: y, width: metrics.cellWidth, height: metrics.cellHeight)
            if unfocused {
                context.setStrokeColor(fillColor)
                context.setLineWidth(1)
                context.stroke(cell.insetBy(dx: 0.5, dy: 0.5))
            } else {
                context.fill(cell)
            }
        case .underline:
            context.fill(CGRect(x: x, y: y, width: metrics.cellWidth, height: thickness))
        case .bar:
            context.fill(CGRect(x: x, y: y, width: thickness, height: metrics.cellHeight))
        }
    }

    private func foreground(of cell: TerminalCell) -> CGColor {
        let alpha: CGFloat = cell.hidden ? 0 : (unfocused ? 0.75 : 1)
        return srgb(CGFloat(cell.fgR) / 255, CGFloat(cell.fgG) / 255, CGFloat(cell.fgB) / 255, alpha)
    }

    private func marginColor(of cell: TerminalCell?) -> CGColor? {
        guard let color = background(of: cell), color != defaultBackground else { return nil }
        return color
    }

    private func background(of cell: TerminalCell?) -> CGColor? {
        guard let cell else { return nil }
        let (r, g, b) = cell.reverse
            ? (cell.fgR, cell.fgG, cell.fgB)
            : (cell.bgR, cell.bgG, cell.bgB)
        return srgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1)
    }

    /// Same-color background runs, excluding the default frame clear.
    public func backgroundRuns(
        for cells: [TerminalCell], selectedColumns: ClosedRange<Int>? = nil
    ) -> [(range: Range<Int>, color: CGColor)] {
        func color(at col: Int) -> CGColor? {
            guard col < cells.count else { return nil }
            let cell = cells[col]
            if selectionInvertFgBg, let selectedColumns, selectedColumns.contains(col) {
                let (r, g, b) = cell.reverse
                    ? (cell.bgR, cell.bgG, cell.bgB)
                    : (cell.fgR, cell.fgG, cell.fgB)
                return srgb(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1)
            }
            return background(of: cell)
        }
        var runs: [(range: Range<Int>, color: CGColor)] = []
        var start = 0
        var runColor = color(at: 0)
        for col in 0...cells.count {
            let c = col < cells.count ? color(at: col) : nil
            if c != runColor || col == cells.count {
                if let runColor, runColor != defaultBackground { runs.append((start..<col, runColor)) }
                start = col
                runColor = c
            }
        }
        return runs
    }
}
