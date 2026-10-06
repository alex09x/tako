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
import simd

extension TerminalMetalFramePlanner {
    func planCellPasses(
        _ cells: TerminalFrame,
        snapshot: FfiSnapshot,
        into stats: inout TerminalMetalFrameStatistics
    ) {
        let currentState = CacheState(
            cols: cells.cols,
            rows: cells.rows,
            drawableWidth: viewport.drawableWidth,
            drawableHeight: viewport.drawableHeight,
            colorEncoding: colorEncoding,
            colorSpace: colorSpace,
            minimumContrast: minimumContrast,
            isFocused: isFocused,
            palette: palette,
            viewportOffset: snapshot.viewportOffset,
            alternateScreen: snapshot.modes.alternateScreen,
            margins: margins,
            cellColorsAreDisplayP3: cellColorsAreDisplayP3
        )

        let isFullInvalidation = cacheState != currentState || rowCache.count != cells.rows
        if isFullInvalidation {
            rowCache = Array(repeating: CachedRow(), count: cells.rows)
            cacheState = currentState
            cachedPackedCells = nil
        }

        var rowsToReplanSet = Set<Int>()
        if isFullInvalidation {
            rowsToReplanSet = Set(0..<cells.rows)
        } else {
            rowsToReplanSet.reserveCapacity(cells.rows)
            for row in snapshot.damagedRows {
                let index = Int(row)
                if index >= 0 && index < cells.rows {
                    rowsToReplanSet.insert(index)
                }
            }
            let bytesPerRow = cells.cols * TerminalCell.byteSize
            for row in 0..<cells.rows {
                if rowsToReplanSet.contains(row) { continue }
                let cached = rowCache[row]
                if !cached.isPopulated {
                    rowsToReplanSet.insert(row)
                    continue
                }
                let currentBlockCursorCol = (blockCursorCell?.row == row) ? blockCursorCell?.col : nil
                if cached.blockCursorCol != currentBlockCursorCol
                    || cached.selectedColumns != selectedColumnsByRow[row] {
                    rowsToReplanSet.insert(row)
                    continue
                }
                if cached.graphemes != frameGraphemes[row] {
                    rowsToReplanSet.insert(row)
                    continue
                }
                stats.comparedPackedCellBytes += bytesPerRow
                if let cachedRowData = cached.packedRowData {
                    if !cells.rowMatches(cachedRowData, row: row) {
                        rowsToReplanSet.insert(row)
                        continue
                    }
                } else if cachedPackedCells.map({ cells.rowMatches($0, row: row) }) != true {
                    rowsToReplanSet.insert(row)
                    continue
                }
            }
        }
        let rowsToReplan = rowsToReplanSet.sorted()
        let replannedRows = rowsToReplan.count

        let cellWidth = metrics.pixelCellWidth
        let cellHeight = metrics.pixelCellHeight
        let defaultBackground = TerminalMetalColor.premultiplied(palette.background)
        var replannedCells = 0

        let margins = self.margins
        let lastCol = cells.cols - 1
        for row in rowsToReplan {
            var currentRow = -1
            var cachedRow = CachedRow()
            let rowGraphemes = frameGraphemes[row]
            var runColor = SIMD4<Float>(repeating: 0)
            var runStart = 0
            var runLength = 0
            let selected = selectedColumnsByRow[row]

            func flushRun() {
                guard runLength > 0 else { return }
                cachedRow.backgroundInstances.append(TerminalMetalBackgroundInstance(
                    x: Float(runStart) * cellWidth,
                    y: Float(currentRow) * cellHeight,
                    width: Float(runLength) * cellWidth,
                    height: cellHeight,
                    color: runColor
                ))
                runLength = 0
            }

            cells.forEachCell(
                inRows: row..<row + 1,
                inColumns: 0..<cells.cols,
                { _, col, cell in
                    currentRow = row
                    cachedRow.visitedCells += 1
                    replannedCells += 1

                    var straightBackground = self.backgroundColor(of: cell)
                    var glyphColor: SIMD4<Float>?
                    if let selected, selected.contains(col) {
                        if self.palette.selectionInvertsColors {
                            glyphColor = straightBackground
                            straightBackground = self.plainForegroundColor(of: cell)
                        } else {
                            glyphColor = self.palette.selectionForeground
                        }
                    }
                    let background = TerminalMetalColor.premultiplied(straightBackground)
                    if margins.fill != .background, col == 0 || col == lastCol, background != defaultBackground {
                        let x = col == 0 ? -margins.left : Float(cells.cols) * cellWidth
                        let width = col == 0 ? margins.left : margins.right
                        if width > 0 {
                            cachedRow.backgroundInstances.append(TerminalMetalBackgroundInstance(
                                x: x, y: Float(row) * cellHeight, width: width, height: cellHeight, color: background
                            ))
                        }
                    }
                    if background == defaultBackground {
                        flushRun()
                    } else if runLength > 0, col == runStart + runLength, background == runColor {
                        runLength += 1
                    } else {
                        flushRun()
                        runColor = background
                        runStart = col
                        runLength = 1
                    }

                    let cluster = cell.hasGrapheme ? rowGraphemes?[col] : nil
                    if !self.appendGlyph(
                        for: cell, cluster: cluster, row: row, col: col, color: glyphColor, into: &cachedRow
                    ) {
                        cachedRow.skippedGlyphs += 1
                    }
                    self.appendDecorations(for: cell, row: row, col: col, into: &cachedRow)
                }
            )
            if currentRow != -1 {
                flushRun()
                cachedRow.blockCursorCol = (blockCursorCell?.row == row) ? blockCursorCell?.col : nil
                cachedRow.selectedColumns = selected
                cachedRow.packedRowData = cells.rowData(for: row)
                cachedRow.graphemes = rowGraphemes
                cachedRow.isPopulated = true
                rowCache[row] = cachedRow
            }
        }

        var visited = 0
        var skippedGlyphs = 0

        for row in 0..<cells.rows {
            let cached = rowCache[row]
            backgroundInstances.append(contentsOf: cached.backgroundInstances)
            glyphInstances.append(contentsOf: cached.glyphInstances)
            colorGlyphInstances.append(contentsOf: cached.colorGlyphInstances)
            decorationInstances.append(contentsOf: cached.decorationInstances)
            visited += cached.visitedCells
            skippedGlyphs += cached.skippedGlyphs
        }

        stats.visitedCells = visited
        stats.skippedGlyphs = skippedGlyphs
        stats.replannedRows = replannedRows
        stats.replannedCells = replannedCells
        cachedPackedCells = cells.packedData
    }

    func appendGlyph(
        for cell: TerminalCell,
        cluster: String? = nil,
        row: Int,
        col: Int,
        color override: SIMD4<Float>? = nil,
        into cachedRow: inout CachedRow
    ) -> Bool {
        guard cell.ch != 0, !cell.hidden else { return false }
        guard cell.ch != 32 || cluster != nil else { return false }
        let before = atlas.generation
        let entry: GlyphAtlasEntry
        if let cluster {
            let face = baseFace(bold: cell.bold, italic: cell.italic)
            entry = atlas.clusterEntry(for: cluster, font: face.font, scale: metrics.scale, emboldened: face.synthetic)
        } else {
            guard let resolved = resolveGlyph(for: cell.ch, bold: cell.bold, italic: cell.italic) else { return false }
            entry = atlas.glyphEntry(
                for: resolved.glyph, font: resolved.font, scale: metrics.scale, emboldened: resolved.emboldened
            )
        }
        if atlas.generation != before, entry.isRasterized {
            atlasGeneration = Int(truncatingIfNeeded: atlas.generation)
            dirtyAtlasPages.insert(entry.pageIndex)
        }
        guard entry.isRasterized, entry.pixelWidth > 0, entry.pixelHeight > 0 else { return false }

        let scale = Float(metrics.scale)
        let originX = Float(col) * metrics.pixelCellWidth
        let baselineY = (Float(row) * metrics.pixelCellHeight + metrics.pixelAscent).rounded()
        let spanWidth = metrics.pixelCellWidth * (cell.wide ? 2 : 1)
        let advance = Float(entry.advance.width) * scale
        let centering = max(0, (spanWidth - advance) / 2)
        let left = originX + centering + Float(entry.bearing.x) * scale
        let top = baselineY - Float(entry.bearing.y) * scale - Float(entry.pixelHeight)

        var alpha: Float = cell.dim ? palette.dimAlpha : 1
        if !isFocused { alpha *= palette.unfocusedTextAlpha }
        let overBlockCursor = blockCursorCell?.row == row && blockCursorCell?.col == col
        let straightColor: SIMD4<Float>
        if entry.pixelFormat == .bgra8Premultiplied {
            straightColor = SIMD4<Float>(1, 1, 1, alpha)
        } else if overBlockCursor {
            straightColor = TerminalMetalColor.enforcingMinimumContrast(
                foreground: SIMD4<Float>(palette.background.x, palette.background.y, palette.background.z, alpha),
                background: palette.cursor,
                ratio: max(minimumContrast, 3),
                encoding: colorEncoding,
                colorSpace: colorSpace
            )
        } else if let override {
            straightColor = SIMD4<Float>(override.x, override.y, override.z, override.w * alpha)
        } else {
            straightColor = foregroundColor(of: cell, alpha: alpha)
        }
        let color = TerminalMetalColor.premultiplied(straightColor)

        var flags: UInt32 = 0
        if cell.bold { flags |= 1 << 0 }
        if cell.italic { flags |= 1 << 1 }
        if cell.wide { flags |= 1 << 2 }
        if entry.pixelFormat == .bgra8Premultiplied { flags |= TerminalMetalGlyphInstance.colorGlyphFlag }

        let instance = TerminalMetalGlyphInstance(
            x: left,
            y: top,
            width: Float(entry.pixelWidth),
            height: Float(entry.pixelHeight),
            uvRect: SIMD4<Float>(
                Float(entry.uvRect.minX),
                Float(entry.uvRect.minY),
                Float(entry.uvRect.maxX),
                Float(entry.uvRect.maxY)
            ),
            color: color,
            atlasPage: UInt32(truncatingIfNeeded: entry.pageIndex),
            flags: flags
        )
        if entry.pixelFormat == .bgra8Premultiplied {
            cachedRow.colorGlyphInstances.append(instance)
        } else {
            cachedRow.glyphInstances.append(instance)
        }
        return true
    }

    func appendDecorations(for cell: TerminalCell, row: Int, col: Int, into cachedRow: inout CachedRow) {
        guard !cell.hidden else { return }
        let hasUnderline = cell.underline || cell.underlineStyle > 0
        guard hasUnderline || cell.strikethrough || cell.overline else { return }
        let scale = Float(metrics.scale)
        let thickness = max(1, scale.rounded())
        let x = Float(col) * metrics.pixelCellWidth
        let y = Float(row) * metrics.pixelCellHeight
        let width = metrics.pixelCellWidth * (cell.wide ? 2 : 1)
        var alpha: Float = cell.dim ? palette.dimAlpha : 1
        if !isFocused { alpha *= palette.unfocusedTextAlpha }
        let background = backgroundColor(of: cell)
        let foreground = foregroundColor(of: cell, alpha: alpha)

        func color(_ raw: SIMD4<Float>) -> SIMD4<Float> {
            TerminalMetalColor.premultiplied(TerminalMetalColor.enforcingMinimumContrast(
                foreground: raw,
                background: background,
                ratio: minimumContrast,
                encoding: colorEncoding,
                colorSpace: colorSpace
            ))
        }
        func append(
            _ style: TerminalMetalDecorationStyle,
            top: Float,
            height: Float,
            lineThickness: Float? = nil,
            color value: SIMD4<Float>
        ) {
            cachedRow.decorationInstances.append(TerminalMetalDecorationInstance(
                rect: SIMD4<Float>(x, top, width, height),
                color: color(value),
                style: style,
                thickness: lineThickness ?? thickness
            ))
        }
        if hasUnderline {
            let style = TerminalMetalDecorationStyle(rawValue: UInt32(max(cell.underlineStyle, 1))) ?? .singleUnderline
            let lineThickness = max(1, Float(metrics.underlineThickness * metrics.scale).rounded())
            let height: Float = style == .doubleUnderline || style == .curlyUnderline ? 4 * lineThickness : lineThickness
            let underline = TerminalMetalColor.rgba(
                r: cell.ulR, g: cell.ulG, b: cell.ulB, alpha: alpha,
                encoding: colorEncoding, colorSpace: colorSpace
            )
            let position = Float(metrics.underlinePosition * metrics.scale).rounded()
            append(style, top: min(y + metrics.pixelCellHeight - height, y + position), height: height,
                   lineThickness: lineThickness, color: underline)
        }
        if cell.strikethrough {
            append(.strikethrough, top: y + (metrics.pixelCellHeight - thickness) / 2, height: thickness, color: foreground)
        }
        if cell.overline {
            append(.overline, top: y, height: thickness, color: foreground)
        }
    }
}
