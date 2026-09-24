import AppKit
import Combine
import Foundation

// What a surface does when a menu item, a keybinding, the command palette or
// AppleScript asks it for something by name.
//
// Upstream sends all of these to its C surface. There is no C surface here,
// so each one is either implemented on the engine and the view directly or
// refused: `performBindingAction` returns false and the menu item is
// disabled. An action that reports success has done what it says.

/// One occurrence of the find needle, in retained rows: row 0 is the oldest
/// line still in scrollback, and the live screen follows the scrollback.
/// Columns are inclusive.
struct SearchMatch: Equatable {
    let row: Int
    let startCol: Int
    let endCol: Int
}

extension Tako.SurfaceView {
    // MARK: - Font size

    /// Smallest and largest point sizes a font size change will produce.
    nonisolated static let fontSizeRange: ClosedRange<CGFloat> = 4...255

    /// Changes the font size for this surface only, relative to the size the
    /// configuration asked for. A cell size fixed in the configuration grows
    /// and shrinks with the font, so the grid keeps its proportions.
    func changeFontSize(_ change: Tako.App.FontSizeModification) {
        let configured = configuredTheme ?? theme
        configuredTheme = configured
        let size: CGFloat
        switch change {
        case .increase(let points): size = theme.fontSize + CGFloat(points)
        case .decrease(let points): size = theme.fontSize - CGFloat(points)
        case .reset: size = configured.fontSize
        }
        let clamped = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        guard clamped != theme.fontSize else { return }

        applyTheme(Self.scaledTheme(configured, toFontSize: clamped))
    }

    /// `theme` with its font size (and any explicit cell size) scaled to
    /// `target`, keeping the grid's proportions. Used both for zooming an
    /// existing surface and for seeding a new one at another surface's
    /// current size (`window-inherit-font-size`).
    static func scaledTheme(_ theme: TerminalTheme, toFontSize target: CGFloat) -> TerminalTheme {
        guard theme.fontSize > 0, target != theme.fontSize else { return theme }
        var next = theme
        let scale = target / theme.fontSize
        next.fontSize = target
        next.cellWidth = theme.cellWidth.map { $0 * scale }
        next.cellHeight = theme.cellHeight.map { $0 * scale }
        return next
    }

    /// Adopts `newTheme` and refits the grid to the new cell size. The theme
    /// rebuilds the renderer on its own; the grid only follows a frame
    /// change, so it is given one at the size it already has.
    func applyTheme(_ newTheme: TerminalTheme) {
        theme = newTheme
        setFrameSize(frame.size)
    }

    // MARK: - Reset

    /// A full reset: screen, scrollback, modes, cursor and charsets go back
    /// to their power-on state. The theme's colors survive it: the engine
    /// holds them as base colors, which a reset returns to.
    public func resetTerminal() {
        core.reset()
        core.markAllDamaged()
        currentSearchMatch = nil
        if let needle = searchState?.needle { runSearch(needle) }
        scrollViewportToBottom()
    }

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
        guard searchState != nil else { return }
        searchState = nil
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
            currentSearchMatch = nil
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
        currentSearchMatch = nil
        let matches = searchMatches(for: needle)
        if let newest = matches.last {
            selectSearchMatch(newest)
        }
        updateSearchCounts(matches)
    }

    /// Moves to the next or previous match, wrapping at either end. False
    /// when no search is open or nothing matches.
    @discardableResult
    func navigateSearch(_ direction: SearchDirection) -> Bool {
        guard let searchState else { return false }
        searchState.writePasteboardNeedle()
        let matches = searchMatches(for: searchState.needle)
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

    // MARK: - Binding actions

    /// Actions the window, the app delegate or the application carry out.
    /// They are sent to whichever of those implements them, the same
    /// selector the menu item uses; the amount in a split resize is the
    /// menu's own, so no other amount is claimed.
    nonisolated static let responderActions: [String: String] = [
        "new_window": "newWindow:",
        "new_tab": "newTab:",
        "close_surface": "close:",
        "close_tab": "closeTab:",
        "close_window": "closeWindow:",
        "close_all_windows": "closeAllWindows:",
        "new_split:right": "splitRight:",
        "new_split:left": "splitLeft:",
        "new_split:down": "splitDown:",
        "new_split:up": "splitUp:",
        "goto_split:previous": "splitMoveFocusPrevious:",
        "goto_split:next": "splitMoveFocusNext:",
        "goto_split:up": "splitMoveFocusAbove:",
        "goto_split:down": "splitMoveFocusBelow:",
        "goto_split:left": "splitMoveFocusLeft:",
        "goto_split:right": "splitMoveFocusRight:",
        "resize_split:up,10": "moveSplitDividerUp:",
        "resize_split:down,10": "moveSplitDividerDown:",
        "resize_split:left,10": "moveSplitDividerLeft:",
        "resize_split:right,10": "moveSplitDividerRight:",
        "equalize_splits": "equalizeSplits:",
        "toggle_split_zoom": "splitZoom:",
        "toggle_fullscreen": "toggleTakoFullScreen:",
        "toggle_command_palette": "toggleCommandPalette:",
        "reset_window_size": "returnToDefaultSize:",
        "prompt_tab_title": "changeTabTitle:",
        "open_config": "openConfig:",
        "reload_config": "reloadConfig:",
        "toggle_quick_terminal": "toggleQuickTerminal:",
        "toggle_visibility": "toggleVisibility:",
        "toggle_secure_input": "toggleSecureInput:",
        "undo": "undo:",
        "redo": "redo:",
    ]

    /// Actions this surface carries out itself.
    nonisolated static let surfaceActions: Set<String> = [
        "increase_font_size", "decrease_font_size", "reset_font_size",
        "reset", "clear_screen",
        "copy_to_clipboard", "paste_from_clipboard", "paste_from_selection", "select_all",
        "scroll_to_top", "scroll_to_bottom", "scroll_page_up", "scroll_page_down", "scroll_page_lines",
        "text", "csi", "esc",
        "start_search", "search", "search_selection", "navigate_search", "end_search", "scroll_to_selection",
    ]

    /// Whether `action` names something this port can do at all. The command
    /// palette offers only these. Whether it succeeds right now is
    /// `performBindingAction`'s answer.
    nonisolated static func isBindingActionSupported(_ action: String) -> Bool {
        let name = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
        return surfaceActions.contains(name) || responderActions[action] != nil
    }

    /// Carries out a keybinding action by its configuration name, such as
    /// `increase_font_size:2` or `navigate_search:next`. True only when the
    /// action was carried out; an action this port does not implement, a
    /// malformed parameter, or one with nothing to act on is false.
    public func performBindingAction(_ action: String) -> Bool {
        let parts = action.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts.first ?? "")
        let param = parts.count > 1 ? String(parts[1]) : nil

        switch name {
        case "increase_font_size", "decrease_font_size":
            let points: Int? = param == nil ? 1 : param.flatMap { Int($0) }
            guard let points, points > 0 else { return false }
            changeFontSize(name == "increase_font_size" ? .increase(points) : .decrease(points))
            return true
        case "reset_font_size":
            changeFontSize(.reset)
            return true
        case "reset":
            resetTerminal()
            return true
        case "clear_screen":
            // The screen only: the engine has no scrollback erase, so what
            // scrolled off stays in history.
            feed(data: Data("\u{1b}[H\u{1b}[2J".utf8))
            scheduleRedraw()
            return true
        case "copy_to_clipboard":
            guard core.hasSelection() else { return false }
            copy(nil)
            return true
        case "paste_from_clipboard":
            guard NSPasteboard.general.string(forType: .string) != nil else { return false }
            paste(nil)
            return true
        case "paste_from_selection":
            guard let text = Self.selectionPasteboard.string(forType: .string) else { return false }
            pasteText(text)
            return true
        case "select_all":
            selectAll(nil)
            return true
        case "scroll_to_top":
            scrollToOffset(scrollbackLength)
            return true
        case "scroll_to_bottom":
            scrollViewportToBottom()
            return true
        case "scroll_page_up":
            scrollViewportUp(lines: rows)
            return true
        case "scroll_page_down":
            scrollViewportDown(lines: rows)
            return true
        case "scroll_page_lines":
            guard let lines = param.flatMap({ Int($0) }), lines != 0 else { return false }
            if lines < 0 { scrollViewportUp(lines: -lines) } else { scrollViewportDown(lines: lines) }
            return true
        case "text", "csi", "esc":
            guard let param, let text = Self.unescapeBindingText(param) else { return false }
            let prefix = name == "csi" ? "\u{1b}[" : (name == "esc" ? "\u{1b}" : "")
            write(prefix + text)
            return true
        case "start_search":
            startSearch(needle: nil)
            return true
        case "search":
            guard let param, !param.isEmpty else { return false }
            startSearch(needle: param)
            return true
        case "search_selection":
            guard core.hasSelection() else { return false }
            selectionForFind(self)
            return true
        case "navigate_search":
            switch param {
            case "next": return navigateSearch(.next)
            case "previous": return navigateSearch(.previous)
            default: return false
            }
        case "end_search":
            guard searchState != nil else { return false }
            findHide(self)
            return true
        case "scroll_to_selection":
            return revealSelection()
        default:
            return performResponderAction(action)
        }
    }

    /// Sends a window- or app-level action to the first of the window's
    /// controller, the app delegate and the application that implements it.
    private func performResponderAction(_ action: String) -> Bool {
        guard let name = Self.responderActions[action] else { return false }
        let selector = NSSelectorFromString(name)
        let targets: [NSObject?] = [window?.windowController, NSApp?.delegate as? NSObject, NSApp]
        for case let target? in targets where target.responds(to: selector) {
            _ = target.perform(selector, with: self)
            return true
        }
        return false
    }

    /// Upstream's escapes for `text:`: `\n`, `\r`, `\t`, `\e`, `\\` and
    /// `\xHH`. Nil for a malformed escape rather than sending something the
    /// binding did not mean.
    nonisolated static func unescapeBindingText(_ raw: String) -> String? {
        var out = ""
        var scalars = raw.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\" else {
                out.unicodeScalars.append(scalar)
                continue
            }
            switch scalars.next() {
            case "n": out += "\n"
            case "r": out += "\r"
            case "t": out += "\t"
            case "e": out += "\u{1b}"
            case "\\": out += "\\"
            case "x":
                guard let high = scalars.next(), let low = scalars.next(),
                      let value = UInt8(String([Character(high), Character(low)]), radix: 16) else { return nil }
                out.unicodeScalars.append(Unicode.Scalar(value))
            default:
                return nil
            }
        }
        return out
    }
}
