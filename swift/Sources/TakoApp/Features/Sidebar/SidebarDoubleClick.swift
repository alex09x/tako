/*
 * tako — A double click on one sidebar row: both clicks on the same row
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// Whether a click on a sidebar row is the second of a double click on that
/// same row. The system's click count alone is not enough: rows can move
/// between the two clicks (a status regroup, a filter, a collapse), and the
/// second click can then land on a row that got only that one click.
struct SidebarDoubleClick {
    struct Click: Equatable {
        let row: String
        /// The physical window: its tab group. Each tab is a window with a
        /// sidebar of its own, so the first click on an inactive tab's row
        /// shows that tab's window, and the second click comes from its sidebar.
        let place: ObjectIdentifier?
        let timestamp: TimeInterval
    }

    private(set) var last: Click?

    /// Records `click`; true when it completes a double click on the row
    /// clicked just before, in the same physical window, within `interval`.
    mutating func isSecond(_ click: Click, clickCount: Int, interval: TimeInterval) -> Bool {
        defer { last = click }
        guard clickCount >= 2, let first = last else { return false }
        return first.row == click.row && first.place == click.place
            && click.timestamp - first.timestamp <= interval
    }

    /// The left mouse release (or press) behind a row's click action, if any.
    @MainActor
    static func click(on row: String, in window: NSWindow?, event: NSEvent?) -> (Click, Int)? {
        guard let event, [.leftMouseUp, .leftMouseDown].contains(event.type) else { return nil }
        let place = window.map { ObjectIdentifier(Tako.CustomTabGroup.group(for: $0)) }
        return (Click(row: row, place: place, timestamp: event.timestamp), event.clickCount)
    }
}
