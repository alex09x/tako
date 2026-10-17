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

/// Output that scrolls moves rows the last frame already planned. The row
/// cache is kept by row index, so one new line at the bottom used to miss
/// it on every row and the whole screen was laid out again, every frame of
/// a streaming log. A row whose cells match one of last frame's rows exactly
/// is that row's plan moved by whole rows instead.
extension TerminalMetalFramePlanner {
    struct ShiftIndex {
        /// Last frame's rows, as they were before this frame replaced any.
        let previous: [CachedRow]
        private var rowsByHash: [Int: [Int]] = [:]

        /// Only rows that move as they are: no cursor drawn over them and no
        /// selection across them, both of which belong to a screen position.
        init(previous: [CachedRow]) {
            self.previous = previous
            for (index, row) in previous.enumerated()
            where row.isPopulated && row.blockCursorCol == nil && row.selectedColumns == nil {
                guard let data = row.packedRowData else { continue }
                rowsByHash[ShiftIndex.hash(data), default: []].append(index)
            }
        }

        /// Another previous row with exactly these cells and clusters, if
        /// any. A row that still holds what it held is not a move: it goes
        /// through the damage path as it always did.
        func match(_ data: Data, graphemes: [Int: String]?, at row: Int) -> Int? {
            guard let candidates = rowsByHash[ShiftIndex.hash(data)] else { return nil }
            let same = candidates.filter { previous[$0].packedRowData == data && previous[$0].graphemes == graphemes }
            guard !same.contains(row) else { return nil }
            return same.first
        }

        /// Every byte counts: rows of a log share long prefixes.
        static func hash(_ data: Data) -> Int {
            var hasher = Hasher()
            data.withUnsafeBytes { hasher.combine(bytes: $0) }
            return hasher.finalize()
        }
    }

    /// Moving a plan by whole rows is exact only when a row is a whole
    /// number of pixels high: glyph baselines are rounded to pixels.
    var canShiftRows: Bool {
        let height = metrics.pixelCellHeight
        return rowShiftEnabled && height > 0 && height == height.rounded()
    }
}

extension TerminalMetalFramePlanner.CachedRow {
    /// The same plan `delta` rows lower (negative: higher).
    func shifted(byRows delta: Int, cellHeight: Float) -> Self {
        guard delta != 0 else { return self }
        let dy = Float(delta) * cellHeight
        var row = self
        for i in row.backgroundInstances.indices { row.backgroundInstances[i].rect.y += dy }
        for i in row.glyphInstances.indices { row.glyphInstances[i].destRect.y += dy }
        for i in row.colorGlyphInstances.indices { row.colorGlyphInstances[i].destRect.y += dy }
        for i in row.decorationInstances.indices { row.decorationInstances[i].rect.y += dy }
        return row
    }
}
