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
import simd

extension TerminalMetalFramePlanner {
    // MARK: - Selection

    public static func selectionSpans(
        for selection: FfiSelectionRange,
        cols: Int,
        rows: Int
    ) -> [TerminalMetalSelectionSpan] {
        guard cols > 0, rows > 0 else { return [] }
        let startRow = Int(selection.startRow)
        let endRow = Int(selection.endRow)
        let startCol = Int(selection.startCol)
        let endCol = Int(selection.endCol)

        let reversed = (endRow, endCol) < (startRow, startCol)
        let firstRow = reversed ? endRow : startRow
        let firstCol = reversed ? endCol : startCol
        let lastRow = reversed ? startRow : endRow
        let lastCol = reversed ? startCol : endCol

        let clampedFirstRow = max(firstRow, 0)
        let clampedLastRow = min(lastRow, rows - 1)
        guard clampedFirstRow <= clampedLastRow else { return [] }

        var spans: [TerminalMetalSelectionSpan] = []
        spans.reserveCapacity(clampedLastRow - clampedFirstRow + 1)
        for row in clampedFirstRow...clampedLastRow {
            var first: Int
            var last: Int
            switch selection.mode {
            case .linear:
                first = row == firstRow ? firstCol : 0
                last = row == lastRow ? lastCol : cols - 1
            case .rectangular:
                first = min(firstCol, lastCol)
                last = max(firstCol, lastCol)
            }
            first = max(first, 0)
            last = min(last, cols - 1)
            guard first <= last else { continue }
            spans.append(TerminalMetalSelectionSpan(row: row, firstColumn: first, lastColumn: last))
        }
        return spans
    }

    func planSelection(
        _ selection: FfiSelectionRange,
        cols: Int,
        rows: Int
    ) {
        let color = TerminalMetalColor.premultiplied(palette.selection)
        for span in Self.selectionSpans(for: selection, cols: cols, rows: rows) {
            selectionInstances.append(TerminalMetalSelectionInstance(
                x: Float(span.firstColumn) * metrics.pixelCellWidth,
                y: Float(span.row) * metrics.pixelCellHeight,
                width: Float(span.columnCount) * metrics.pixelCellWidth,
                height: metrics.pixelCellHeight,
                color: color
            ))
        }
    }

    // MARK: - Kitty graphics

    func planImages(
        _ placements: [FfiGraphicsPlacement],
        cols: Int,
        rows: Int,
        provider: (UInt32) -> FfiStoredImage?,
        metadataProvider: (UInt32) -> FfiGraphicsImageMetadata?,
        into stats: inout TerminalMetalFrameStatistics
    ) {
        guard !placements.isEmpty else { return }
        imageInstances.reserveCapacity(placements.count)
        var skipped = 0
        var metadataByImageId: [UInt32: FfiGraphicsImageMetadata] = [:]
        var missingImageIds = Set<UInt32>()
        for placement in placements {
            guard let row = Int(exactly: placement.row), let col = Int(exactly: placement.col),
                  row >= 0, row < rows, col >= 0, col < cols else {
                skipped += 1
                continue
            }
            let metadata: FfiGraphicsImageMetadata? = {
                if let cached = metadataByImageId[placement.imageId] { return cached }
                if missingImageIds.contains(placement.imageId) { return nil }
                let resolved: FfiGraphicsImageMetadata?
                if let value = metadataProvider(placement.imageId) {
                    resolved = value
                } else if let stored = provider(placement.imageId) {
                    resolved = FfiGraphicsImageMetadata(
                        format: stored.format,
                        width: stored.width,
                        height: stored.height,
                        generation: 0
                    )
                } else {
                    resolved = nil
                }
                if let resolved {
                    metadataByImageId[placement.imageId] = resolved
                } else {
                    missingImageIds.insert(placement.imageId)
                }
                return resolved
            }()
            guard let metadata,
                  metadata.width > 0, metadata.height > 0,
                  let width = Int(exactly: metadata.width), let height = Int(exactly: metadata.height) else {
                skipped += 1
                continue
            }
            imageInstances.append(TerminalMetalImageInstance(
                x: Float(col) * metrics.pixelCellWidth,
                y: Float(row) * metrics.pixelCellHeight,
                width: Float(width),
                height: Float(height),
                imageId: placement.imageId
            ))
        }
        stats.skippedPlacements = skipped
    }

    // MARK: - Cursor

    func planCursor(
        _ snapshot: FfiSnapshot,
        cols: Int,
        rows: Int
    ) {
        guard snapshot.cursorVisible else { return }
        guard snapshot.viewportOffset == 0 else { return }
        guard !snapshot.cursorStyle.blinking || !isFocused || cursorBlinkPhaseOn else { return }
        guard let row = Int(exactly: snapshot.cursorRow), let col = Int(exactly: snapshot.cursorCol),
              row >= 0, row < rows, col >= 0, col < cols else { return }

        let x = Float(col) * metrics.pixelCellWidth
        let y = Float(row) * metrics.pixelCellHeight
        let width = metrics.pixelCellWidth
        let height = metrics.pixelCellHeight
        let thickness = cursorThickness.map { max(1, Float($0) * Float(metrics.scale)) }
            ?? max(1, (2 * Float(metrics.scale)).rounded())
        let color = TerminalMetalColor.premultiplied(palette.cursor)
        let blink: UInt32 = snapshot.cursorStyle.blinking ? 1 : 0

        func append(_ rect: SIMD4<Float>, _ shape: TerminalMetalCursorShape) {
            cursorInstances.append(TerminalMetalCursorInstance(
                rect: rect,
                shape: shape,
                blinkState: blink,
                color: color
            ))
        }

        switch snapshot.cursorStyle.shape {
        case .block:
            guard isFocused else {
                append(SIMD4<Float>(x, y, width, thickness), .hollowBlock)
                append(SIMD4<Float>(x, y + height - thickness, width, thickness), .hollowBlock)
                append(SIMD4<Float>(x, y + thickness, thickness, height - 2 * thickness), .hollowBlock)
                append(
                    SIMD4<Float>(x + width - thickness, y + thickness, thickness, height - 2 * thickness),
                    .hollowBlock
                )
                return
            }
            blockCursorCell = (row, col)
            append(SIMD4<Float>(x, y, width, height), .block)
        case .underline:
            append(SIMD4<Float>(x, y + height - thickness, width, thickness), .underline)
        case .bar:
            append(SIMD4<Float>(x, y, thickness, height), .bar)
        }
    }

    // MARK: - Margins

    func planMargins(_ cells: TerminalFrame, snapshot: FfiSnapshot, rows: Int) {
        guard margins.fill != .background, cells.cols > 0, rows > 0 else { return }
        let cellWidth = metrics.pixelCellWidth
        let cellHeight = metrics.pixelCellHeight
        let defaultBackground = TerminalMetalColor.premultiplied(palette.background)
        for (row, y, height) in [(0, -margins.top, margins.top), (rows - 1, Float(rows) * cellHeight, margins.bottom)]
        where height > 0 {
            var colors: [SIMD4<Float>] = []
            colors.reserveCapacity(cells.cols)
            cells.forEachCell(inRows: row..<row + 1, inColumns: 0..<cells.cols) { _, _, cell in
                colors.append(TerminalMetalColor.premultiplied(self.backgroundColor(of: cell)))
            }
            if margins.fill == .extend, !snapshot.modes.alternateScreen,
               colors.contains(defaultBackground) {
                continue
            }
            for (col, color) in colors.enumerated() where color != defaultBackground {
                backgroundInstances.append(TerminalMetalBackgroundInstance(
                    x: Float(col) * cellWidth, y: y, width: cellWidth, height: height, color: color
                ))
            }
        }
    }

    // MARK: - Cell colors

    var cellColorConversion: TerminalMetalColorSpace {
        cellColorsAreDisplayP3 ? .sRGB : colorSpace
    }

    public func backgroundColor(of cell: TerminalCell) -> SIMD4<Float> {
        let (r, g, b) = cell.reverse
            ? (cell.fgR, cell.fgG, cell.fgB)
            : (cell.bgR, cell.bgG, cell.bgB)
        return TerminalMetalColor.rgba(r: r, g: g, b: b, encoding: colorEncoding, colorSpace: cellColorConversion)
    }

    func plainForegroundColor(of cell: TerminalCell) -> SIMD4<Float> {
        let (r, g, b) = cell.reverse
            ? (cell.bgR, cell.bgG, cell.bgB)
            : (cell.fgR, cell.fgG, cell.fgB)
        return TerminalMetalColor.rgba(r: r, g: g, b: b, encoding: colorEncoding, colorSpace: cellColorConversion)
    }

    public func foregroundColor(of cell: TerminalCell, alpha: Float = 1) -> SIMD4<Float> {
        let (r, g, b) = cell.reverse
            ? (cell.fgR, cell.fgG, cell.fgB)
            : (cell.fgR, cell.fgG, cell.fgB)
        let foreground = TerminalMetalColor.rgba(
            r: r, g: g, b: b, alpha: alpha,
            encoding: colorEncoding, colorSpace: cellColorConversion
        )
        return TerminalMetalColor.enforcingMinimumContrast(
            foreground: foreground,
            background: backgroundColor(of: cell),
            ratio: minimumContrast,
            encoding: colorEncoding,
            colorSpace: colorSpace
        )
    }
}
