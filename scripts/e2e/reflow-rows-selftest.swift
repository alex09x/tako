/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// The persist-reflow guard's arithmetic, without a terminal:
//
//   swiftc -o /tmp/reflow-rows scripts/e2e/ReflowRows.swift scripts/e2e/reflow-rows-selftest.swift && /tmp/reflow-rows

import Foundation

@main
enum ReflowRowsSelfTest {
    static let marker = "REFLOW_MARKER_PARTA_" + String(repeating: "J", count: 42)
        + "_SPLIT_MID_" + String(repeating: "K", count: 42)

    /// The rows a terminal of `cols` columns shows for `before`, the marker
    /// on a line of its own, then `after`.
    static func screen(cols: Int, before: [String] = ["$ python3 -c ..."], after: [String] = ["$ "]) -> [String] {
        var rows = before
        var rest = Substring(marker)
        while !rest.isEmpty { rows.append(String(rest.prefix(cols))); rest = rest.dropFirst(cols) }
        return rows + after
    }

    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "ok  " : "FAIL") \(name)")
            if !ok { failures += 1 }
        }

        for cols in [14, 46, 58, 80, 94] {
            check("\(cols) cols: found at row 1", wrappedMarkerStart(marker, in: screen(cols: cols), cols: cols) == 1)
        }
        // What the hosted CI captured at 46 columns: the capture command's own echo, no marker.
        let echo = (0..<12).map { _ in String(repeating: "x", count: 46) }
        check("46 cols: an echo-only capture is refused", wrappedMarkerStart(marker, in: echo, cols: 46) == nil)
        // The old two-row assumption: at 46 columns the marker takes three rows.
        check("46 cols: three rows", (marker.count + 45) / 46 == 3)
        check("46 cols: missing last row refused",
              wrappedMarkerStart(marker, in: Array(screen(cols: 46).dropLast(2)), cols: 46) == nil)
        var short = screen(cols: 46)
        short[2].removeLast()
        check("46 cols: a short middle row refused", wrappedMarkerStart(marker, in: short, cols: 46) == nil)
        check("rows of 46 checked as 47 refused", wrappedMarkerStart(marker, in: screen(cols: 46), cols: 47) == nil)
        check("one row holding all of it refused", wrappedMarkerStart(marker, in: ["$ x", marker, "$ "], cols: 200) == nil)
        // 14 columns: nine rows, and the marker's first part is wider than a row.
        check("14 cols: nine rows", (marker.count + 13) / 14 == 9)
        // Nine rows followed by a long prompt wrapped over six more need more
        // than 12: a 12-line read from the bottom cuts the marker's start.
        let tall = screen(cols: 14, after: Array(repeating: "prompt-part-xx", count: 6))
        check("14 cols, wrapped prompt: a 12-row tail misses the start",
              wrappedMarkerStart(marker, in: Array(tall.suffix(12)), cols: 14) == nil)
        check("14 cols, wrapped prompt: the whole viewport finds it", wrappedMarkerStart(marker, in: tall, cols: 14) == 1)

        print(failures == 0 ? "reflow rows: ok" : "reflow rows: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
