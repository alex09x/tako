/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension TakoTerminalNSView {
    public var cellWidth: CGFloat { renderer.metrics.cellWidth }
    public var cellHeight: CGFloat { renderer.metrics.cellHeight }

    /// Bottom-left of a cell in view coordinates.
    /// The lower-left corner of a cell, in view coordinates. The exact inverse
    /// of `cellAt`, so anything positioned by it lands on the cell a click
    /// there would report.
    public func cellOrigin(row: Int, col: Int) -> NSPoint {
        let layout = gridLayout
        return NSPoint(
            x: layout.left + CGFloat(col) * cellWidth,
            y: bounds.height - layout.top - CGFloat(row + 1) * cellHeight
        )
    }

    /// Where the grid on screen sits in this view: inside the configured
    /// padding, centred in the spare space with `window-padding-balance`.
    /// Every path that draws the grid or maps a point to a cell uses this one.
    ///
    /// Command marks are chrome of their own, not theme padding: while they
    /// are on, the left edge keeps at least their gutter -- the marks', or
    /// the wider one their durations or start times need. It follows the
    /// setting, not whether a mark exists, so the grid never jumps as marks
    /// come and go or a full-screen program hides them.
    var layoutTheme: TerminalTheme {
        var effectiveTheme = theme
        if commandMarksEnabled {
            let minGutter: CGFloat = commandTimestampsEnabled ? 64.0
                : commandDurationsEnabled ? 44.0 : Self.commandMarkGutter
            if effectiveTheme.padding.left < minGutter {
                effectiveTheme.padding.left = minGutter
            }
        }
        return effectiveTheme
    }

    /// The narrowest gutter that shows command marks: the 3 pt mark, 2 pt
    /// before the grid and 1 pt from the edge.
    public static let commandMarkGutter: CGFloat = 6

    /// The padding the grid really sits in: the theme's, widened for the
    /// command-mark gutter. Size a view for a grid of N cells with this.
    public var effectivePadding: TerminalPadding { layoutTheme.padding }

    /// Fit and paint with the same gutter, including opt-in duration labels.
    public func fittedGridLayout(for size: CGSize) -> TerminalGridLayout {
        TerminalGridLayout(
            viewSize: size,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            theme: layoutTheme
        )
    }

    func updateCommandGutterLayout() {
        needsLayout = true
        updateGutterMarks()
        updateScroller()
    }

    public var gridLayout: TerminalGridLayout {
        TerminalGridLayout(
            viewSize: bounds.size,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            theme: layoutTheme,
            cols: cols,
            rows: rows
        )
    }

    /// The grid cell under a point in this view. Public so a host that adds
    /// its own pointer handling on top resolves cells the same way.
    public func cellAt(_ point: NSPoint) -> (row: Int, col: Int) {
        gridLayout.cell(
            atTopLeftPoint: CGPoint(x: point.x, y: bounds.height - point.y),
            cols: cols,
            rows: rows
        )
    }
}
#endif
