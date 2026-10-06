/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Combine
import Foundation

/// One occurrence of the find needle, in retained rows: row 0 is the oldest
/// line still in scrollback, and the live screen follows the scrollback.
/// Columns are inclusive.
struct SearchMatch: Equatable {
    let row: Int
    let startCol: Int
    let endCol: Int
}

extension Tako.SurfaceView {
    // MARK: - Find

    /// Opens the find bar, or moves the keyboard to it when it is open.
    @IBAction public func find(_ sender: Any) {
        startSearch(needle: nil)
    }

    /// Searches for the current selection.
    @IBAction public func selectionForFind(_ sender: Any) {
        guard let text = core.selectedText(), !text.isEmpty else { return }
        startSearch(needle: text)
    }

    /// Scrolls until the selection is on screen.
    @IBAction public func scrollToSelection(_ sender: Any) {
        _ = revealSelection()
    }

    @IBAction public func findNext(_ sender: Any) {
        _ = navigateSearch(.next)
    }

    @IBAction public func findPrevious(_ sender: Any) {
        _ = navigateSearch(.previous)
    }

    /// Closes the find bar and gives the keys back to the terminal. The last
    /// match stays selected, so it can be copied.
    @IBAction public func findHide(_ sender: Any) {
        cancelPendingSearchHitRefresh()
        guard searchState != nil else { return }
        searchState = nil
        searchHitRetainedRows = []
        window?.makeFirstResponder(self)
    }

    enum SearchDirection {
        /// Toward older output, which is where a terminal search usually
        /// wants to go next.
        case next
        /// Toward newer output.
        case previous
    }

    /// Opens the find bar with `needle`, or with the shared find pasteboard's
    /// needle when there is none.
    func startSearch(needle: String?) {
        // Secure-input sessions are strictly excluded from search (G5)
        guard !self.isSecureInput && !SecureInput.shared.isSecure(for: self) else {
            return
        }
        if let searchState {
            if let needle { searchState.needle = needle }
            NotificationCenter.default.post(name: .takoSearchFocus, object: self)
        } else {
            searchState = Tako.OSSurfaceView.SearchState(
                from: Tako.Action.StartSearch(needle: needle),
                pasteboard: findPasteboard)
        }
    }

    /// Follows the find bar's needle for as long as the bar is open.
    func searchStateDidChange() {
        searchNeedleCancellable = nil
        guard let searchState else {
            cancelPendingSearchHitRefresh()
            currentSearchMatch = nil
            searchHitRetainedRows = []
            return
        }
        searchNeedleCancellable = searchState.$needle
            .removeDuplicates()
            .sink { [weak self] needle in
                MainActor.assumeIsolated { self?.runSearch(needle) }
            }
    }

    /// Searches everything the terminal holds for `needle` and selects the
    /// newest match.
    func runSearch(_ needle: String) {
        cancelPendingSearchHitRefresh()
        currentSearchMatch = nil
        let matches = searchMatches(for: needle)
        searchHitRetainedRows = Array(Set(matches.map { UInt64($0.row) })).sorted()
        if let newest = matches.last {
            selectSearchMatch(newest)
        }
        updateSearchCounts(matches)
    }

    /// Moves to the next or previous match, wrapping at either end. False
    /// when no search is open or nothing matches.
    @discardableResult
    func navigateSearch(_ direction: SearchDirection) -> Bool {
        cancelPendingSearchHitRefresh()
        guard let searchState else { return false }
        searchState.writePasteboardNeedle()
        let matches = searchMatches(for: searchState.needle)
        searchHitRetainedRows = Array(Set(matches.map { UInt64($0.row) })).sorted()
        guard let first = matches.first, let last = matches.last else {
            currentSearchMatch = nil
            updateSearchCounts(matches)
            return false
        }
        let target: SearchMatch
        if let current = currentSearchMatch {
            switch direction {
            case .next: target = matches.last(where: { Self.precedes($0, current) }) ?? last
            case .previous: target = matches.first(where: { Self.precedes(current, $0) }) ?? first
            }
        } else {
            target = last
        }
        selectSearchMatch(target)
        updateSearchCounts(matches)
        return true
    }

    private static func precedes(_ a: SearchMatch, _ b: SearchMatch) -> Bool {
        (a.row, a.startCol) < (b.row, b.startCol)
    }

    /// The bar counts from the newest match, which is where a search starts.
    private func updateSearchCounts(_ matches: [SearchMatch]) {
        guard let searchState else { return }
        searchState.total = UInt(matches.count)
        searchState.selected = currentSearchMatch
            .flatMap { matches.firstIndex(of: $0) }
            .map { UInt(matches.count - 1 - $0) }
    }

    /// Recomputes search matches and updates scrollbar track hit marks whenever
    /// terminal content changes or reflow occurs.
    func refreshSearchHitRows() {
        cancelPendingSearchHitRefresh()
        guard let searchState, !searchState.needle.isEmpty else {
            if !searchHitRetainedRows.isEmpty {
                searchHitRetainedRows = []
            }
            return
        }
        let matches = searchMatches(for: searchState.needle)
        searchHitRetainedRows = Array(Set(matches.map { UInt64($0.row) })).sorted()
        if let current = currentSearchMatch {
            if !matches.contains(current) {
                let remapped = matches.min(by: {
                    let d0 = abs($0.row - current.row)
                    let d1 = abs($1.row - current.row)
                    if d0 != d1 { return d0 < d1 }
                    return abs($0.startCol - current.startCol) < abs($1.startCol - current.startCol)
                })
                currentSearchMatch = remapped
                if let remapped {
                    selectSearchMatch(remapped)
                } else {
                    core.clearSelection()
                }
            }
        }
        updateSearchCounts(matches)
    }

    /// Every match of `needle` in scrollback and on screen, oldest first.
    /// Case-insensitive. A match does not continue across a soft wrap.
    func searchMatches(for needle: String) -> [SearchMatch] {
        guard !needle.isEmpty else { return [] }
        var matches: [SearchMatch] = []
        for (row, line) in retainedRows().enumerated() {
            let text = line.text
            var from = text.startIndex
            while from < text.endIndex,
                  let range = text.range(of: needle, options: .caseInsensitive, range: from..<text.endIndex),
                  !range.isEmpty {
                let first = text.unicodeScalars.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.unicodeScalars.distance(from: text.startIndex, to: range.upperBound)
                let endCol = end < line.columns.count ? line.columns[end] - 1 : line.width - 1
                matches.append(SearchMatch(row: row, startCol: line.columns[first], endCol: endCol))
                from = range.upperBound
            }
        }
        return matches
    }

    /// One retained row as text, with the column each scalar starts at.
    struct RetainedRow {
        var text = ""
        var columns: [Int] = []
        var width = 0
    }

    /// Every retained row, oldest first, read a screenful at a time through
    /// the engine's packed viewport. The viewport is put back afterwards.
    func retainedRows() -> [RetainedRow] {
        let cols = Int(core.cols())
        let rows = Int(core.rows())
        let scrollback = Int(core.scrollbackLen())
        guard cols > 0, rows > 0 else { return [] }
        let stride = cols * 16
        let saved = core.viewportOffset()
        defer { core.scrollTo(offset: saved) }

        var result = [RetainedRow?](repeating: nil, count: scrollback + rows)
        var top = 0
        while top < scrollback + rows {
            let offset = max(scrollback - top, 0)
            core.scrollTo(offset: UInt32(offset))
            let viewportTop = scrollback - offset
            let packed = [UInt8](core.viewportPacked())
            for r in 0..<rows where viewportTop + r < result.count && result[viewportTop + r] == nil {
                guard packed.count >= (r + 1) * stride else { break }
                var line = RetainedRow(width: cols)
                for c in 0..<cols {
                    let o = r * stride + c * 16
                    let value = UInt32(packed[o]) | UInt32(packed[o + 1]) << 8
                        | UInt32(packed[o + 2]) << 16 | UInt32(packed[o + 3]) << 24
                    // Zero is the second half of a wide character.
                    guard value != 0, let scalar = Unicode.Scalar(value) else { continue }
                    line.text.unicodeScalars.append(scalar)
                    line.columns.append(c)
                }
                result[viewportTop + r] = line
            }
            top = viewportTop + rows
        }
        return result.map { $0 ?? RetainedRow(width: cols) }
    }

    /// Selects `match`, scrolling it into view if it is off screen.
    func selectSearchMatch(_ match: SearchMatch) {
        let scrollback = Int(core.scrollbackLen())
        let rows = Int(core.rows())
        var top = scrollback - Int(core.viewportOffset())
        if match.row < top || match.row >= top + rows {
            // A third of the way down, so the lines before it show too.
            top = min(max(match.row - rows / 3, 0), scrollback)
            scrollToOffset(scrollback - top)
        }
        let row = UInt32(max(match.row - top, 0))
        core.startSelection(row: row, col: UInt32(match.startCol), mode: .linear)
        core.extendSelection(row: row, col: UInt32(max(match.endCol, match.startCol)))
        currentSearchMatch = match
        scheduleRedraw()
    }

    /// Selects a hit from the engine's search (`TakoCore.searchChunk`) and
    /// scrolls it into view. The engine checks it is still there and selects
    /// it in one step, so output in between cannot move the selection; false
    /// when it is gone, and then nothing changes.
    @discardableResult
    func selectSearchHit(needle: String, hit: FfiSearchHit) -> Bool {
        guard core.selectSearchHit(needle: needle, hit: hit) else { return false }
        currentSearchMatch = nil
        notifyScrollPositionIfChanged()
        scheduleRedraw()
        return true
    }

    /// Scrolls to the first screenful, from the live screen up, that shows
    /// part of the selection. False when there is no selection.
    func revealSelection() -> Bool {
        guard core.hasSelection() else { return false }
        if core.selectionRange() != nil { return true }
        let scrollback = Int(core.scrollbackLen())
        let rows = max(Int(core.rows()), 1)
        let saved = core.viewportOffset()
        for offset in Array(Swift.stride(from: 0, to: scrollback, by: rows)) + [scrollback] {
            core.scrollTo(offset: UInt32(offset))
            if core.selectionRange() != nil {
                core.scrollTo(offset: saved)
                scrollToOffset(offset)
                return true
            }
        }
        core.scrollTo(offset: saved)
        return false
    }

    // MARK: - Menu validation

    /// Find items are enabled only when they would do something. Nil for an
    /// item that is not a find item.
    func validateFindItem(_ action: Selector?) -> Bool? {
        switch action {
        case #selector(find(_:)):
            return true
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return (searchState?.total ?? 0) > 0
        case #selector(findHide(_:)):
            return searchState != nil
        case #selector(selectionForFind(_:)), #selector(scrollToSelection(_:)):
            return core.hasSelection()
        default:
            return nil
        }
    }
}
