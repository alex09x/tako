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

// What a surface does when a menu item, a keybinding, the command palette or
// AppleScript asks it for something by name.
//
// Upstream sends all of these to its C surface. There is no C surface here,
// so each one is either implemented on the engine and the view directly or
// refused: `performBindingAction` returns false and the menu item is
// disabled. An action that reports success has done what it says.

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
        "search_command_history": "toggleCommandPalette:",
        "find_all": "toggleFindAll:",
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
        "jump_to_prompt", "select_command_output", "select_output",
        "toggle_output_filter", "focus_mode",
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
            handlePaste(text)
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
        case "jump_to_prompt":
            switch param {
            case "previous", "up", nil:
                _ = jumpToPreviousPrompt()
                return true
            case "next", "down":
                _ = jumpToNextPrompt()
                return true
            default:
                return false
            }
        case "select_command_output", "select_output":
            return selectCommandOutput()
        case "toggle_output_filter", "focus_mode":
            toggleOutputFilter()
            return true
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

/// Observable state for the Output Filter (Focus Mode) overlay bar (E5).
public final class OutputFilterState: ObservableObject, @unchecked Sendable {
    @Published public var query: String = ""
    @Published public var isRegex: Bool = false
    @Published public var matchCount: Int = 0
    @Published public var totalCount: Int = 0

    public init(query: String = "", isRegex: Bool = false, matchCount: Int = 0, totalCount: Int = 0) {
        self.query = query
        self.isRegex = isRegex
        self.matchCount = matchCount
        self.totalCount = totalCount
    }
}



