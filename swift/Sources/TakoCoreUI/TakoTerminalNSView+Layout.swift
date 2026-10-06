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
    public var gridLayout: TerminalGridLayout {
        var effectiveTheme = theme
        if commandMarksEnabled && (commandDurationsEnabled || commandTimestampsEnabled) {
            let minGutter: CGFloat = commandTimestampsEnabled ? 64.0 : 44.0
            if effectiveTheme.padding.left < minGutter {
                effectiveTheme.padding.left = minGutter
            }
        }
        return TerminalGridLayout(
            viewSize: bounds.size,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            theme: effectiveTheme,
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
