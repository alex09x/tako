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
    // MARK: - Output Filtering / Focus Mode (E5)

    /// Packs a simple ASCII string into terminal cell data for notification or placeholder rows.
    static func packAsciiRow(_ text: String, cols: Int) -> Data {
        var data = Data(count: cols * 16)
        let scalars = Array(text.unicodeScalars)
        for i in 0..<min(scalars.count, cols) {
            let ch = scalars[i].value
            let byteOffset = i * 16
            var val = ch.littleEndian
            withUnsafeBytes(of: &val) { ptr in
                data.replaceSubrange(byteOffset..<(byteOffset + 4), with: ptr)
            }
            data[byteOffset + 4] = 160
            data[byteOffset + 5] = 160
            data[byteOffset + 6] = 160
        }
        return data
    }

    /// Collects all retained scrollback and live viewport lines in chronological order without mutating session history (E5).
    public func collectAllRetainedLines() -> [FilteredOutputLine] {
        let totalScrollback = Int(core.scrollbackLen())
        let totalViewport = Int(core.rows())
        let cols = Int(core.cols())
        let bytesPerRow = cols * 16

        let originalOffset = core.viewportOffset()
        defer {
            core.scrollTo(offset: originalOffset)
        }

        var collectedBlocks: [(offset: Int, lines: [FilteredOutputLine])] = []

        var offset = 0
        while offset <= totalScrollback {
            core.scrollTo(offset: UInt32(offset))
            let frameData = core.viewportPacked()
            let graphemes = core.viewportGraphemes()

            var blockLines: [FilteredOutputLine] = []
            for r in 0..<totalViewport {
                let (lineText, _) = Self.rowText(core.viewportRow(row: UInt32(r)))
                let byteStart = r * bytesPerRow
                let byteEnd = min(byteStart + bytesPerRow, frameData.count)
                let packedRow = byteStart < frameData.count ? frameData.subdata(in: byteStart..<byteEnd) : Data(count: bytesPerRow)
                blockLines.append(FilteredOutputLine(
                    retainedRowIndex: 0,
                    text: lineText,
                    packedCells: packedRow,
                    graphemes: graphemes
                ))
            }
            collectedBlocks.append((offset: offset, lines: blockLines))

            if offset == totalScrollback {
                break
            }
            if offset + totalViewport >= totalScrollback {
                offset = totalScrollback
            } else {
                offset += totalViewport
            }
        }

        var result: [FilteredOutputLine] = []
        var nextExpectedIndex = 0
        for i in (0..<collectedBlocks.count).reversed() {
            let block = collectedBlocks[i]
            let lines = block.lines
            if i == collectedBlocks.count - 1 && collectedBlocks.count > 1 {
                let nextBlockOffset = collectedBlocks[i - 1].offset
                let takeCount = block.offset - nextBlockOffset
                let slice = lines.prefix(takeCount)
                for l in slice {
                    result.append(FilteredOutputLine(retainedRowIndex: nextExpectedIndex, text: l.text, packedCells: l.packedCells, graphemes: l.graphemes))
                    nextExpectedIndex += 1
                }
            } else {
                for l in lines {
                    result.append(FilteredOutputLine(retainedRowIndex: nextExpectedIndex, text: l.text, packedCells: l.packedCells, graphemes: l.graphemes))
                    nextExpectedIndex += 1
                }
            }
        }
        return result
    }

    /// Constructs the temporary rendered frame projecting only matching lines (Focus mode - E5).
    func filteredRenderFrame() -> FfiRenderFrame {
        var baseFrame = core.renderFrame()
        let totalCols = Int(core.cols())
        let totalRows = Int(core.rows())
        let bytesPerRow = totalCols * 16

        var packedData = Data(count: totalRows * bytesPerRow)
        var allGraphemes: [FfiGrapheme] = []

        let matchCount = outputFilterMatchingLines.count
        if matchCount == 0 {
            if !outputFilterQuery.isEmpty {
                let msg = " [Focus mode: no lines match '\(outputFilterQuery)']"
                let msgRow = Self.packAsciiRow(msg, cols: totalCols)
                packedData.replaceSubrange(0..<min(bytesPerRow, msgRow.count), with: msgRow)
            }
        } else {
            let maxOffset = max(0, matchCount - totalRows)
            let clampedOffset = max(0, min(outputFilterScrollOffset, maxOffset))
            let startIndex = max(0, matchCount - totalRows - clampedOffset)
            let endIndex = min(matchCount, startIndex + totalRows)
            let slice = outputFilterMatchingLines[startIndex..<endIndex]

            var targetRow = 0
            for line in slice {
                guard targetRow < totalRows else { break }
                let rowData = line.packedCells.prefix(bytesPerRow)
                let destOffset = targetRow * bytesPerRow
                if rowData.count == bytesPerRow {
                    packedData.replaceSubrange(destOffset..<(destOffset + bytesPerRow), with: rowData)
                } else if rowData.count > 0 {
                    packedData.replaceSubrange(destOffset..<(destOffset + rowData.count), with: rowData)
                }
                allGraphemes.append(contentsOf: line.graphemes)
                targetRow += 1
            }
        }

        baseFrame.packedCells = packedData
        baseFrame.graphemes = allGraphemes
        baseFrame.snapshot.cursorVisible = false
        return baseFrame
    }

    /// Sets or updates the active output filter (Focus mode - E5).
    @objc open func setOutputFilter(query: String, isRegex: Bool = false) {
        outputFilterQuery = query
        outputFilterIsRegex = isRegex
        isOutputFilterActive = !query.isEmpty
        outputFilterScrollOffset = 0
        refreshOutputFilterMatches()
    }

    /// Deactivates focus mode and immediately restores the complete scrollback without buffer mutation (E5).
    @objc open func clearOutputFilter() {
        isOutputFilterActive = false
        outputFilterQuery = ""
        outputFilterIsRegex = false
        outputFilterMatchingLines.removeAll()
        outputFilterScrollOffset = 0
        updateScroller()
        scheduleRedraw()
        onOutputFilterChanged?(false, 0, 0)
    }

    /// Toggles output filtering / focus mode on or off (E5).
    @objc open func toggleOutputFilter() {
        if isOutputFilterActive {
            clearOutputFilter()
        } else {
            isOutputFilterActive = true
            refreshOutputFilterMatches()
        }
    }

    /// Refreshes matching lines for the active query across all retained scrollback lines.
    public func refreshOutputFilterMatches() {
        guard isOutputFilterActive else {
            outputFilterMatchingLines.removeAll()
            return
        }
        let allLines = collectAllRetainedLines()
        guard !outputFilterQuery.isEmpty else {
            outputFilterMatchingLines = allLines
            onOutputFilterChanged?(true, allLines.count, allLines.count)
            updateScroller()
            scheduleRedraw()
            return
        }

        let matching: [FilteredOutputLine]
        if outputFilterIsRegex {
            if let regex = try? NSRegularExpression(pattern: outputFilterQuery, options: [.caseInsensitive]) {
                matching = allLines.filter { line in
                    let range = NSRange(location: 0, length: (line.text as NSString).length)
                    return regex.firstMatch(in: line.text, options: [], range: range) != nil
                }
            } else {
                matching = allLines.filter { line in
                    line.text.localizedCaseInsensitiveContains(outputFilterQuery)
                }
            }
        } else {
            matching = allLines.filter { line in
                line.text.localizedCaseInsensitiveContains(outputFilterQuery)
            }
        }

        outputFilterMatchingLines = matching
        let maxOffset = max(0, matching.count - Int(core.rows()))
        if outputFilterScrollOffset > maxOffset {
            outputFilterScrollOffset = maxOffset
        }
        onOutputFilterChanged?(true, matching.count, allLines.count)
        updateScroller()
        scheduleRedraw()
    }

    /// A row's text, each cell's whole cluster, and the column every UTF-16
    /// unit of it came from: a cluster or a wide glyph is not one unit per
    /// column.
    static func rowText(_ cells: [FfiCell]) -> (text: String, columns: [Int]) {
        var text = ""
        var columns: [Int] = []
        for (col, cell) in cells.enumerated() where cell.ch != 0 {
            let piece = cell.grapheme ?? TerminalRenderer.string(for: cell.ch)
            text += piece
            columns.append(contentsOf: repeatElement(col, count: piece.utf16.count))
        }
        return (text, columns)
    }
}
#endif
