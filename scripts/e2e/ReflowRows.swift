/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

/// Where a marker printed at the start of a line sits among a terminal's
/// physical rows at `cols` columns: the index of its first row when it fills
/// exactly ceil(count / cols) rows -- its first `cols` characters, every row
/// before the last full width, the last row its exact rest -- and no single
/// row holds all of it. Nil otherwise. A pure function, so its arithmetic is
/// checked without a terminal (scripts/e2e/reflow-rows-selftest.swift).
func wrappedMarkerStart(_ marker: String, in rows: [String], cols: Int) -> Int? {
    guard cols > 0, marker.count > cols else { return nil }
    guard !rows.contains(where: { $0.contains(marker) }) else { return nil }
    let span = (marker.count + cols - 1) / cols
    let tail = marker.count - (span - 1) * cols
    guard let start = rows.firstIndex(where: { $0 == String(marker.prefix(cols)) }),
          start + span <= rows.count,
          rows[start..<(start + span - 1)].allSatisfy({ $0.count == cols }),
          rows[start + span - 1].hasPrefix(String(marker.suffix(tail))),
          rows[start..<(start + span)].joined().hasPrefix(marker) else { return nil }
    return start
}
