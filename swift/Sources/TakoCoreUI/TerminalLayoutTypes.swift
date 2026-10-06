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

/// Space between a terminal view's edges and its grid, in points.
public struct TerminalPadding: Equatable, Sendable {
    public var left: CGFloat
    public var right: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    public init(uniform value: CGFloat) {
        self.init(left: value, right: value, top: value, bottom: value)
    }

    /// `a` for both sides or `a,b` for leading and trailing; nil for
    /// anything else, including a negative value.
    static func pair(_ value: String) -> (CGFloat, CGFloat)? {
        let parts = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let first = CGFloat(parts[0]!)
        return (first, parts.count == 2 ? CGFloat(parts[1]!) : first)
    }
}

/// Where a terminal's grid sits in its view: as many whole cells as fit
/// inside the padding, placed at the top-left of what is left -- or, with
/// `window-padding-balance`, centred in it, so the leftover is spread over
/// both sides instead of all landing at the right and the bottom.
public struct TerminalGridLayout: Equatable, Sendable {
    public let cols: Int
    public let rows: Int
    /// Points from the view's left edge to the grid's.
    public let left: CGFloat
    /// Points from the view's top edge to the grid's.
    public let top: CGFloat
    public let cellSize: CGSize

    public init(viewSize: CGSize, cellSize: CGSize, padding: TerminalPadding, balance: Bool) {
        let cellW = max(cellSize.width, 1)
        let cellH = max(cellSize.height, 1)
        let usableW = viewSize.width - padding.left - padding.right
        let usableH = viewSize.height - padding.top - padding.bottom
        // A hair of tolerance: a size made as cells times cell width must fit
        // that many cells, however the product rounded.
        cols = max(Int((usableW / cellW + 1e-6).rounded(.down)), 1)
        rows = max(Int((usableH / cellH + 1e-6).rounded(.down)), 1)
        let spareW = max(0, usableW - CGFloat(cols) * cellW)
        let spareH = max(0, usableH - CGFloat(rows) * cellH)
        left = padding.left + (balance ? (spareW / 2).rounded(.down) : 0)
        top = padding.top + (balance ? (spareH / 2).rounded(.down) : 0)
        self.cellSize = CGSize(width: cellW, height: cellH)
    }

    public init(viewSize: CGSize, cellSize: CGSize, theme: TerminalTheme) {
        self.init(viewSize: viewSize, cellSize: cellSize, padding: theme.padding, balance: theme.windowPaddingBalance)
    }

    /// Where a grid of a known size sits -- the one on screen, which lags the
    /// view's size while a resize settles.
    public init(viewSize: CGSize, cellSize: CGSize, theme: TerminalTheme, cols: Int, rows: Int) {
        let fitted = TerminalGridLayout(viewSize: viewSize, cellSize: cellSize, theme: theme)
        let cellW = fitted.cellSize.width
        let cellH = fitted.cellSize.height
        let padding = theme.padding
        let spareW = max(0, viewSize.width - padding.left - padding.right - CGFloat(cols) * cellW)
        let spareH = max(0, viewSize.height - padding.top - padding.bottom - CGFloat(rows) * cellH)
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        left = padding.left + (theme.windowPaddingBalance ? (spareW / 2).rounded(.down) : 0)
        top = padding.top + (theme.windowPaddingBalance ? (spareH / 2).rounded(.down) : 0)
        self.cellSize = fitted.cellSize
    }

    /// Points from the grid's right edge to the view's.
    public func right(in viewSize: CGSize) -> CGFloat {
        max(0, viewSize.width - left - CGFloat(cols) * cellSize.width)
    }

    /// Points from the grid's bottom edge to the view's.
    public func bottom(in viewSize: CGSize) -> CGFloat {
        max(0, viewSize.height - top - CGFloat(rows) * cellSize.height)
    }

    /// The grid cell under a point measured from the view's top-left, with
    /// the grid's own size as the bound. A point in the padding maps to the
    /// nearest edge cell.
    public func cell(atTopLeftPoint point: CGPoint, cols: Int, rows: Int) -> (row: Int, col: Int) {
        let col = Int(((point.x - left) / cellSize.width).rounded(.down))
        let row = Int(((point.y - top) / cellSize.height).rounded(.down))
        return (min(max(row, 0), max(rows - 1, 0)), min(max(col, 0), max(cols - 1, 0)))
    }
}
