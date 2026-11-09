/*
 * tako — Desktop settings wording for keyboard actions and their groups
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Titles from the reference (prefs-keys.js PF_KA / PF_KCATS) for the
/// actions KeybindRegistry already has; ids, defaults and grouping stay native.
enum DesktopKeysCopy {
    static func title(_ action: String) -> String {
        if action.hasPrefix("goto_tab:"), let n = Int(action.dropFirst(9)) { return "Tab \(n)" }
        return titles[action] ?? KeybindRegistry.allActions.first { $0.id == action }?.title ?? action
    }

    static func group(_ category: KeybindCategory) -> (title: String, note: String) {
        switch category {
        case .tabs: ("Tabs & Windows", "A tab appears as a session in the sidebar")
        case .splits: ("Session Terminals", "Split panes")
        case .workspaces: ("Workspace", "")
        case .terminal: ("Terminal & Application", "")
        case .edit: ("Editing & Search", "")
        }
    }

    private static let titles: [String: String] = [
        "new_tab": "New Tab", "close_surface": "Close Terminal or Tab", "close_tab": "Close Entire Tab",
        "goto_tab:next": "Next Tab", "goto_tab:previous": "Previous Tab",
        "move_tab:1": "Move Tab Down", "move_tab:-1": "Move Tab Up",
        "new_window": "New Window", "close_window": "Close Window", "close_all_windows": "Close All Windows",
        "new_split:right": "Split Right", "new_split:down": "Split Down",
        "goto_split:next": "Next Terminal", "goto_split:previous": "Previous Terminal",
        "goto_split:left": "Terminal to the Left", "goto_split:right": "Terminal to the Right",
        "goto_split:up": "Terminal Above", "goto_split:down": "Terminal Below",
        "toggle_split_zoom": FloatingPaneCopy.maximize(.normal), "equalize_splits": "Equalize Panes",
        "resize_split:left,10": "Move Divider Left", "resize_split:right,10": "Move Divider Right",
        "resize_split:up,10": "Move Divider Up", "resize_split:down,10": "Move Divider Down",
        "next_workspace": "Next Workspace", "previous_workspace": "Previous Workspace", "new_workspace": "New Workspace",
        "quit": "Quit Tako", "increase_font_size:1": "Increase Font Size", "decrease_font_size:1": "Decrease Font Size",
        "reset_font_size": "Reset Font Size", "jump_to_prompt:previous": "Previous Command",
        "jump_to_prompt:next": "Next Command", "toggle_quick_terminal": "Quick Terminal",
        "reload_config": "Reload Configuration", "open_config": "Settings", "toggle_command_palette": "Command Palette",
        "copy_to_clipboard": "Copy", "paste_from_clipboard": "Paste", "paste_from_selection": "Paste Selection",
        "undo": "Undo", "redo": "Redo", "select_all": "Select All", "select_command_output": "Select Command Output",
        "start_search": "Find in Terminal", "find_all": "Find in All Terminals",
        "navigate_search:next": "Find Next", "navigate_search:previous": "Find Previous",
    ]

    /// A built-in shortcut as a config trigger, modifiers in Tako's order.
    static func trigger(for shortcut: SwiftUI.KeyboardShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.control) { parts.append("ctrl") }
        if shortcut.modifiers.contains(.option) { parts.append("opt") }
        if shortcut.modifiers.contains(.shift) { parts.append("shift") }
        if shortcut.modifiers.contains(.command) { parts.append("cmd") }
        let key: String
        switch shortcut.key {
        case .return: key = "return"; case .tab: key = "tab"; case .space: key = "space"
        case .escape: key = "escape"; case .delete: key = "backspace"; case .deleteForward: key = "delete"
        case .upArrow: key = "up"; case .downArrow: key = "down"; case .leftArrow: key = "left"; case .rightArrow: key = "right"
        default:
            let c = shortcut.key.character
            key = ["[": "bracket_left", "]": "bracket_right", "=": "equal", "-": "minus", ",": "comma",
                   ".": "period", "/": "slash", "`": "grave_accent", ";": "semicolon", "'": "quote",
                   "\\": "backslash"][String(c)] ?? String(c).lowercased()
        }
        return (parts + [key]).joined(separator: "+")
    }

    /// What a query can match for an action: titles, id, and its current and
    /// built-in shortcut both as glyphs ("⇧⌘D") and as triggers in either
    /// modifier order ("cmd+shift+d", "shift+cmd+d").
    static func searchTexts(_ action: String, current: String?) -> [String] {
        var texts = [title(action), action, KeybindRegistry.allActions.first { $0.id == action }?.title ?? ""]
        var triggers: [String] = []
        if let builtin = KeybindRegistry.defaultShortcut(for: action) {
            texts.append(KeybindRegistry.format(shortcut: builtin))
            triggers.append(trigger(for: builtin))
        }
        if let current { triggers.append(current); texts.append(KeybindRegistry.format(trigger: current)) }
        for t in triggers {
            texts.append(t)
            let parts = t.split(separator: "+").map(String.init)
            if parts.count > 1 { texts.append((parts.dropLast().reversed() + [parts.last!]).joined(separator: "+")) }
        }
        return texts
    }

    /// "⇧⌘D" → ["⇧", "⌘", "D"]: each modifier is its own key cap.
    static func caps(_ formatted: String) -> [String] {
        var caps: [String] = []
        var rest = Substring(formatted)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) { caps.append(String(first)); rest = rest.dropFirst() }
        if !rest.isEmpty { caps.append(String(rest)) }
        return caps
    }
}

/// A shortcut as separate key caps, or «None» when nothing is assigned.
struct DesktopShortcutCaps: View {
    let text: String?
    let palette: DesktopPalette

    var body: some View {
        HStack(spacing: 3) {
            if let text {
                ForEach(Array(DesktopKeysCopy.caps(text).enumerated()), id: \.offset) { DesktopKeyCap(symbol: $0.element, palette: palette) }
            } else {
                Text("None").font(.system(size: DesktopSettingsStyle.captionSize)).foregroundStyle(Color(palette.muted))
            }
        }
    }
}
