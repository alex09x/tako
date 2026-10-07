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
import SwiftUI

/// Category of terminal keybindings.
public enum KeybindCategory: String, CaseIterable, Identifiable {
    case tabs = "Tabs"
    case splits = "Splits"
    case workspaces = "Workspaces"
    case terminal = "Terminal"
    case edit = "Edit & Search"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .tabs: return "macwindow"
        case .splits: return "rectangle.split.2x1"
        case .workspaces: return "square.grid.2x2"
        case .terminal: return "apple.terminal"
        case .edit: return "pencil.and.list.clipboard"
        }
    }
}

/// Metadata and description for a configurable action in Tako.
public struct KeybindActionItem: Identifiable {
    public let id: String
    public let title: String
    public let category: KeybindCategory
    public let description: String

    public init(id: String, title: String, category: KeybindCategory, description: String = "") {
        self.id = id
        self.title = title
        self.category = category
        self.description = description
    }
}

public enum KeybindRegistry {
    /// Canonical list of user-configurable actions with human-friendly names.
    public static let allActions: [KeybindActionItem] = [
        // Tabs
        KeybindActionItem(id: "new_tab", title: "New Tab", category: .tabs),
        KeybindActionItem(id: "close_surface", title: "Close Split / Tab", category: .tabs),
        KeybindActionItem(id: "close_tab", title: "Close Entire Tab", category: .tabs),
        KeybindActionItem(id: "goto_tab:next", title: "Next Tab", category: .tabs),
        KeybindActionItem(id: "goto_tab:previous", title: "Previous Tab", category: .tabs),
        KeybindActionItem(id: "move_tab:1", title: "Move Tab Right", category: .tabs),
        KeybindActionItem(id: "move_tab:-1", title: "Move Tab Left", category: .tabs),
        KeybindActionItem(id: "new_window", title: "New Window", category: .tabs),
        KeybindActionItem(id: "close_window", title: "Close Window", category: .tabs),
        KeybindActionItem(id: "goto_tab:1", title: "Switch to Tab 1", category: .tabs),
        KeybindActionItem(id: "goto_tab:2", title: "Switch to Tab 2", category: .tabs),
        KeybindActionItem(id: "goto_tab:3", title: "Switch to Tab 3", category: .tabs),
        KeybindActionItem(id: "goto_tab:4", title: "Switch to Tab 4", category: .tabs),
        KeybindActionItem(id: "goto_tab:5", title: "Switch to Tab 5", category: .tabs),

        // Splits
        KeybindActionItem(id: "new_split:right", title: "Split Right (Vertical)", category: .splits),
        KeybindActionItem(id: "new_split:down", title: "Split Down (Horizontal)", category: .splits),
        KeybindActionItem(id: "goto_split:next", title: "Focus Next Split", category: .splits),
        KeybindActionItem(id: "goto_split:previous", title: "Focus Previous Split", category: .splits),
        KeybindActionItem(id: "goto_split:left", title: "Focus Left Split", category: .splits),
        KeybindActionItem(id: "goto_split:right", title: "Focus Right Split", category: .splits),
        KeybindActionItem(id: "goto_split:up", title: "Focus Split Above", category: .splits),
        KeybindActionItem(id: "goto_split:down", title: "Focus Split Below", category: .splits),
        KeybindActionItem(id: "toggle_split_zoom", title: "Zoom / Fullscreen Split", category: .splits),
        KeybindActionItem(id: "equalize_splits", title: "Equalize Splits", category: .splits),
        KeybindActionItem(id: "resize_split:left,10", title: "Resize Split Left", category: .splits),
        KeybindActionItem(id: "resize_split:right,10", title: "Resize Split Right", category: .splits),
        KeybindActionItem(id: "resize_split:up,10", title: "Resize Split Up", category: .splits),
        KeybindActionItem(id: "resize_split:down,10", title: "Resize Split Down", category: .splits),

        // Workspaces
        KeybindActionItem(id: "next_workspace", title: "Next Workspace", category: .workspaces),
        KeybindActionItem(id: "previous_workspace", title: "Previous Workspace", category: .workspaces),
        KeybindActionItem(id: "new_workspace", title: "New Workspace", category: .workspaces),

        // Terminal
        KeybindActionItem(id: "increase_font_size:1", title: "Increase Font Size", category: .terminal),
        KeybindActionItem(id: "decrease_font_size:1", title: "Decrease Font Size", category: .terminal),
        KeybindActionItem(id: "reset_font_size", title: "Reset Font Size", category: .terminal),
        KeybindActionItem(id: "toggle_quick_terminal", title: "Toggle Quick Terminal", category: .terminal),
        KeybindActionItem(id: "reload_config", title: "Reload Configuration", category: .terminal),
        KeybindActionItem(id: "open_config", title: "Open Settings / Config", category: .terminal),

        // Edit & Search
        KeybindActionItem(id: "copy_to_clipboard", title: "Copy", category: .edit),
        KeybindActionItem(id: "paste_from_clipboard", title: "Paste", category: .edit),
        KeybindActionItem(id: "paste_from_selection", title: "Paste from Selection", category: .edit),
        KeybindActionItem(id: "undo", title: "Undo", category: .edit),
        KeybindActionItem(id: "redo", title: "Redo", category: .edit),
        KeybindActionItem(id: "select_all", title: "Select All", category: .edit),
        KeybindActionItem(id: "start_search", title: "Find in Current Tab", category: .edit),
        KeybindActionItem(id: "find_all", title: "Find in All Tabs", category: .edit),
    ]

    /// Default shortcut for action ID.
    public static func defaultShortcut(for action: String) -> SwiftUI.KeyboardShortcut? {
        if action == "next_workspace" {
            return .init("]", modifiers: [.control, .option])
        }
        if action == "previous_workspace" {
            return .init("[", modifiers: [.control, .option])
        }
        if action == "new_workspace" {
            return .init("n", modifiers: [.control, .option])
        }
        return Tako.Config.defaultKeyboardShortcuts[action]
    }

    /// Formats a trigger or KeyboardShortcut into user-visible symbols (e.g. ⌘⇧↩).
    public static func format(shortcut: SwiftUI.KeyboardShortcut) -> String {
        var str = ""
        if shortcut.modifiers.contains(.control) { str += "⌃" }
        if shortcut.modifiers.contains(.option) { str += "⌥" }
        if shortcut.modifiers.contains(.shift) { str += "⇧" }
        if shortcut.modifiers.contains(.command) { str += "⌘" }

        switch shortcut.key {
        case .return: str += "↩"
        case .tab: str += "⇥"
        case .space: str += "Space"
        case .escape: str += "⎋"
        case .delete: str += "⌫"
        case .deleteForward: str += "⌦"
        case .upArrow: str += "↑"
        case .downArrow: str += "↓"
        case .leftArrow: str += "←"
        case .rightArrow: str += "→"
        case .pageUp: str += "⇞"
        case .pageDown: str += "⇟"
        case .home: str += "↖"
        case .end: str += "↘"
        default:
            str += shortcut.key.character.description.uppercased()
        }
        return str
    }

    /// Formats a raw Tako trigger string (e.g. "cmd+shift+d" or "opt+cmd+=") into display symbols.
    public static func format(trigger: String) -> String {
        let parts = trigger.split(separator: "+").map(String.init)
        guard let keyPart = parts.last else { return trigger }
        var str = ""
        for mod in parts.dropLast() {
            switch mod.lowercased() {
            case "ctrl", "control": str += "⌃"
            case "opt", "alt", "option": str += "⌥"
            case "shift": str += "⇧"
            case "cmd", "command", "super": str += "⌘"
            default: break
            }
        }
        switch keyPart.lowercased() {
        case "return", "enter": str += "↩"
        case "tab": str += "⇥"
        case "space": str += "Space"
        case "escape": str += "⎋"
        case "backspace": str += "⌫"
        case "delete": str += "⌦"
        case "up", "arrow_up": str += "↑"
        case "down", "arrow_down": str += "↓"
        case "left", "arrow_left": str += "←"
        case "right", "arrow_right": str += "→"
        default:
            str += keyPart.uppercased()
        }
        return str
    }
}
