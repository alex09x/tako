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
        KeybindActionItem(id: "goto_tab:6", title: "Switch to Tab 6", category: .tabs),
        KeybindActionItem(id: "goto_tab:7", title: "Switch to Tab 7", category: .tabs),
        KeybindActionItem(id: "goto_tab:8", title: "Switch to Tab 8", category: .tabs),
        KeybindActionItem(id: "goto_tab:9", title: "Switch to Tab 9", category: .tabs),

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
        case "bracket_left": str += "["
        case "bracket_right": str += "]"
        case "minus": str += "-"
        case "equal": str += "="
        case "grave_accent": str += "`"
        case "backslash": str += "\\"
        case "semicolon": str += ";"
        case "quote": str += "'"
        case "comma": str += ","
        case "period": str += "."
        case "slash": str += "/"
        case "page_up": str += "⇞"
        case "page_down": str += "⇟"
        case "home": str += "↖"
        case "end": str += "↘"
        default:
            str += keyPart.uppercased()
        }
        return str
    }

    /// Resolves macOS physical hardware virtual keycode into canonical Tako key name.
    public static func keyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        // Letters (Hardware ANSI keycodes, layout-agnostic)
        case 0: return "a"; case 1: return "s"; case 2: return "d"; case 3: return "f"
        case 4: return "h"; case 5: return "g"; case 6: return "z"; case 7: return "x"
        case 8: return "c"; case 9: return "v"; case 11: return "b"; case 12: return "q"
        case 13: return "w"; case 14: return "e"; case 15: return "r"; case 16: return "y"
        case 17: return "t"; case 31: return "o"; case 32: return "u"; case 34: return "i"
        case 35: return "p"; case 37: return "l"; case 38: return "j"; case 40: return "k"
        case 45: return "n"; case 46: return "m"

        // Numbers
        case 18: return "1"; case 19: return "2"; case 20: return "3"; case 21: return "4"
        case 23: return "5"; case 22: return "6"; case 26: return "7"; case 28: return "8"
        case 25: return "9"; case 29: return "0"

        // Symbols
        case 27: return "minus"; case 24: return "equal"
        case 33: return "bracket_left"; case 30: return "bracket_right"
        case 42: return "backslash"; case 41: return "semicolon"
        case 39: return "quote"; case 43: return "comma"
        case 47: return "period"; case 44: return "slash"; case 50: return "grave_accent"

        // Navigation & Special
        case 36, 76: return "return"; case 48: return "tab"; case 49: return "space"
        case 51: return "backspace"; case 53: return "escape"; case 117: return "delete"
        case 123: return "left"; case 124: return "right"; case 125: return "down"; case 126: return "up"
        case 116: return "page_up"; case 121: return "page_down"; case 115: return "home"; case 119: return "end"

        // Function keys
        case 122: return "f1"; case 120: return "f2"; case 99: return "f3"; case 118: return "f4"
        case 96: return "f5"; case 97: return "f6"; case 98: return "f7"; case 100: return "f8"
        case 101: return "f9"; case 109: return "f10"; case 103: return "f11"; case 111: return "f12"

        default:
            return nil
        }
    }

    /// Resolves macOS physical hardware virtual keycode into canonical unshifted key character or symbol.
    public static func canonicalKeyEquivalent(for keyCode: UInt16) -> String? {
        guard let name = keyName(for: keyCode) else { return nil }
        switch name {
        case "bracket_left": return "["
        case "bracket_right": return "]"
        case "minus": return "-"
        case "equal": return "="
        case "backslash": return "\\"
        case "semicolon": return ";"
        case "quote": return "'"
        case "comma": return ","
        case "period": return "."
        case "slash": return "/"
        case "grave_accent": return "`"
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "escape": return "\u{1b}"
        case "up": return "\u{F700}"
        case "down": return "\u{F701}"
        case "left": return "\u{F702}"
        case "right": return "\u{F703}"
        case "page_up": return "\u{F72C}"
        case "page_down": return "\u{F72D}"
        case "home": return "\u{F729}"
        case "end": return "\u{F72B}"
        default:
            if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...35).contains(n),
               let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                return String(Character(scalar))
            } else if name.count == 1 {
                return name
            }
            return nil
        }
    }
}
