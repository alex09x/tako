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
import Foundation
import SwiftUI
import TakoKit

extension Tako.Config {
    enum KeybindOverride {
        case shortcut(SwiftUI.KeyboardShortcut)
        case unbound
    }

    /// Normalizes alias action names to their canonical forms.
    static func canonicalActionName(_ action: String) -> String {
        switch action {
        case "copy":
            return "copy_to_clipboard"
        case "paste":
            return "paste_from_clipboard"
        case "select_output":
            return "select_command_output"
        case "jump_to_prompt:up", "jump_to_prompt":
            return "jump_to_prompt:previous"
        case "jump_to_prompt:down":
            return "jump_to_prompt:next"
        case "previous_tab":
            return "goto_tab:previous"
        case "next_tab":
            return "goto_tab:next"
        default:
            return action
        }
    }

    /// The shortcut for a named action: the config's `keybind` lines, then the
    /// defaults below. Menu items, tab labels and the command palette show it, and
    /// the menu is what makes it fire -- there is no other keybinding layer, so a
    /// `keybind` for an action with no menu item does nothing.
    func keyboardShortcut(for action: String) -> SwiftUI.KeyboardShortcut? {
        let canonical = Self.canonicalActionName(action)
        switch keybindOverrides[canonical] ?? keybindOverrides[action] {
        case .shortcut(let s): return s
        case .unbound: return nil
        case nil: return Self.defaultKeyboardShortcuts[canonical] ?? Self.defaultKeyboardShortcuts[action]
        }
    }

    /// Upstream's defaults for the bindings its UI asks about. The tab
    /// ones matter most: the tab bar labels each tab with them.
    /// Mirrors the macOS-specific defaults upstream's `Keybinds.init`
    /// bakes into its builds. This table is
    /// only the *fallback* for actions with no keybind in the loaded
    /// config -- upstream gets these for free from its own config
    /// layer; this port doesn't have that layer, so leaving an action
    /// out of this table silently strips its menu shortcut down to
    /// nothing (`syncMenuShortcut` clears `keyEquivalent` when lookup
    /// fails). That's exactly what happened to Copy: `copy_to_clipboard`
    /// was missing here, so Cmd+C had no menu item to land on at all,
    /// on top of the separate `copy(_:)` responder-chain bug.
    static let defaultKeyboardShortcuts: [String: SwiftUI.KeyboardShortcut] = [
        "goto_tab:1": .init("1", modifiers: .command),
        "goto_tab:2": .init("2", modifiers: .command),
        "goto_tab:3": .init("3", modifiers: .command),
        "goto_tab:4": .init("4", modifiers: .command),
        "goto_tab:5": .init("5", modifiers: .command),
        "goto_tab:6": .init("6", modifiers: .command),
        "goto_tab:7": .init("7", modifiers: .command),
        "goto_tab:8": .init("8", modifiers: .command),
        "goto_tab:9": .init("9", modifiers: .command),
        "goto_tab:previous": .init(.tab, modifiers: [.control, .shift]),
        "goto_tab:next": .init(.tab, modifiers: .control),
        "move_tab:-1": .init("[", modifiers: [.command, .shift]),
        "move_tab:1": .init("]", modifiers: [.command, .shift]),
        "new_tab": .init("t", modifiers: .command),
        "new_window": .init("n", modifiers: .command),
        "new_split:right": .init("d", modifiers: .command),
        "new_split:down": .init("d", modifiers: [.command, .shift]),
        "close_surface": .init("w", modifiers: .command),
        "toggle_quick_terminal": .init("`", modifiers: [.command, .shift]),
        "reload_config": .init(",", modifiers: [.command, .shift]),
        "open_config": .init(",", modifiers: .command),
        "goto_split:previous": .init("[", modifiers: .command),
        "goto_split:next": .init("]", modifiers: .command),
        "goto_split:up": .init(.upArrow, modifiers: [.command, .option]),
        "goto_split:down": .init(.downArrow, modifiers: [.command, .option]),
        "goto_split:left": .init(.leftArrow, modifiers: [.command, .option]),
        "goto_split:right": .init(.rightArrow, modifiers: [.command, .option]),
        "toggle_split_zoom": .init(.return, modifiers: [.command, .shift]),
        "resize_split:up,10": .init(.upArrow, modifiers: [.command, .control, .option]),
        "resize_split:down,10": .init(.downArrow, modifiers: [.command, .control, .option]),
        "resize_split:left,10": .init(.leftArrow, modifiers: [.command, .control, .option]),
        "resize_split:right,10": .init(.rightArrow, modifiers: [.command, .control, .option]),
        "equalize_splits": .init("=", modifiers: [.command, .option]),
        "quit": .init("q", modifiers: .command),
        "close_tab": .init("w", modifiers: [.command, .option]),
        "close_window": .init("w", modifiers: [.command, .shift]),
        "close_all_windows": .init("w", modifiers: [.command, .shift, .option]),
        "undo": .init("z", modifiers: .command),
        "redo": .init("z", modifiers: [.command, .shift]),
        "copy_to_clipboard": .init("c", modifiers: .command),
        "paste_from_clipboard": .init("v", modifiers: .command),
        "paste_from_selection": .init("v", modifiers: [.command, .shift]),
        "select_all": .init("a", modifiers: .command),
        "increase_font_size:1": .init("=", modifiers: .command),
        "decrease_font_size:1": .init("-", modifiers: .command),
        "reset_font_size": .init("0", modifiers: .command),
        "start_search": .init("f", modifiers: .command),
        "find_all": .init("f", modifiers: [.command, .shift]),
        "search_selection": .init("e", modifiers: .command),
        "scroll_to_selection": .init("j", modifiers: .command),
        "navigate_search:next": .init("g", modifiers: .command),
        "navigate_search:previous": .init("g", modifiers: [.command, .shift]),
        "jump_to_prompt:previous": .init(.upArrow, modifiers: .command),
        "jump_to_prompt:next": .init(.downArrow, modifiers: .command),
        "select_command_output": .init("a", modifiers: [.command, .shift]),
        "toggle_output_filter": .init("f", modifiers: [.command, .option]),
        "focus_mode": .init("f", modifiers: [.command, .option]),
    ]

    /// Parses `keybind = <trigger>=<action>` lines (e.g. `cmd+L=goto_split:left`,
    /// `super+d=unbind`) into per-action overrides, in file order. `super` is Tako
    /// config's own name for Command. A trigger does one thing, so binding it takes it
    /// away from whichever action held it before -- a default or an earlier line --
    /// and `unbind` only takes it away. `keybind = clear` drops every binding,
    /// defaults included. A line whose trigger cannot be a menu shortcut (an unknown
    /// key or modifier, a `>` sequence) is skipped rather than bound to a guess.
    static func parseKeybindOverrides(_ lines: [String]) -> [String: KeybindOverride] {
        var result: [String: KeybindOverride] = [:]
        func current(_ action: String) -> SwiftUI.KeyboardShortcut? {
            let canonical = canonicalActionName(action)
            switch result[canonical] ?? result[action] {
            case .shortcut(let s): return s
            case .unbound: return nil
            case nil: return defaultKeyboardShortcuts[canonical] ?? defaultKeyboardShortcuts[action]
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "clear" {
                result = defaultKeyboardShortcuts.mapValues { _ in KeybindOverride.unbound }
                continue
            }
            guard let eq = triggerSeparator(in: line) else { continue }
            let rawAction = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !rawAction.isEmpty, let shortcut = parseTrigger(line[..<eq]) else { continue }
            let canonical = canonicalActionName(rawAction)

            let holders = Set(defaultKeyboardShortcuts.keys).union(result.keys)
            for holder in holders where current(holder) == shortcut {
                result[holder] = .unbound
                let holderCanonical = canonicalActionName(holder)
                result[holderCanonical] = .unbound
            }
            if rawAction != "unbind" {
                result[canonical] = .shortcut(shortcut)
                if canonical != rawAction {
                    result[rawAction] = .shortcut(shortcut)
                }
            }
        }
        return result
    }

    /// The `=` between trigger and action. An `=` right after a `+` (or at the very
    /// start) is the key itself, as in `cmd+==increase_font_size:1`.
    private static func triggerSeparator(in line: String) -> String.Index? {
        var index = line.startIndex
        while let eq = line[index...].firstIndex(of: "=") {
            if eq != line.startIndex, line[line.index(before: eq)] != "+" {
                return eq
            }
            index = line.index(after: eq)
        }
        return nil
    }

    /// Parses a single trigger like `cmd+L`, `super+shift+d` or
    /// `global:cmd+grave_accent` into a `KeyboardShortcut`. A letter is lowercased for
    /// the `KeyEquivalent` (upstream's trigger syntax is case-insensitive); no shift is
    /// implied by an uppercase letter here -- that inference belongs to
    /// `MenuShortcutKey`, which converts the result afterward.
    private static func parseTrigger(_ trigger: Substring) -> SwiftUI.KeyboardShortcut? {
        var trigger = trigger.trimmingCharacters(in: .whitespaces)[...]
        // Where the binding applies (everywhere, globally, ...) does not change which
        // key the menu item shows.
        while let prefix = triggerPrefixes.first(where: { trigger.hasPrefix($0) }) {
            trigger = trigger.dropFirst(prefix.count)
        }
        // A leader sequence (`ctrl+a>n`) has no single key a menu item can carry.
        guard !trigger.isEmpty, !trigger.contains(">") else { return nil }

        // `+` separates parts; the key `+` itself is spelled `plus`.
        let parts = trigger.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyPart = parts.last, let key = keyEquivalent(named: keyPart) else { return nil }

        var modifiers: SwiftUI.EventModifiers = []
        for part in parts.dropLast() {
            switch part.trimmingCharacters(in: .whitespaces).lowercased() {
            case "cmd", "command", "super": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "opt", "option": modifiers.insert(.option)
            default: return nil
            }
        }
        return SwiftUI.KeyboardShortcut(key, modifiers: modifiers)
    }

    private static let triggerPrefixes = ["all:", "global:", "unconsumed:", "performable:"]

    /// A single character is that key; anything longer must be one of upstream's key
    /// names (both its current W3C-style names and the older ones configs still use).
    private static func keyEquivalent(named name: String) -> SwiftUI.KeyEquivalent? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.count == 1, let char = name.lowercased().first {
            return SwiftUI.KeyEquivalent(char)
        }
        let lower = name.lowercased()
        if let named = namedKeys[lower] {
            return named
        }
        if lower.hasPrefix("key_"), lower.count == 5, let char = lower.last, char.isLetter {
            return SwiftUI.KeyEquivalent(char)
        }
        if lower.hasPrefix("digit_"), lower.count == 7, let char = lower.last, char.isNumber {
            return SwiftUI.KeyEquivalent(char)
        }
        if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1...35).contains(n),
           let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            return SwiftUI.KeyEquivalent(Character(scalar))
        }
        return nil
    }

    private static let namedKeys: [String: SwiftUI.KeyEquivalent] = {
        var keys: [String: SwiftUI.KeyEquivalent] = [
            "grave_accent": "`", "backquote": "`",
            "minus": "-", "equal": "=",
            "bracket_left": "[", "left_bracket": "[",
            "bracket_right": "]", "right_bracket": "]",
            "backslash": "\\", "semicolon": ";",
            "quote": "'", "apostrophe": "'",
            "comma": ",", "period": ".", "slash": "/",
            "plus": "+",
            "space": .space, "enter": .return, "return": .return, "tab": .tab,
            "escape": .escape, "backspace": .delete, "delete": .deleteForward,
            "arrow_up": .upArrow, "up": .upArrow,
            "arrow_down": .downArrow, "down": .downArrow,
            "arrow_left": .leftArrow, "left": .leftArrow,
            "arrow_right": .rightArrow, "right": .rightArrow,
            "home": .home, "end": .end,
            "page_up": .pageUp, "page_down": .pageDown,
        ]
        for (digit, word) in ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"].enumerated() {
            keys[word] = SwiftUI.KeyEquivalent(Character(String(digit)))
        }
        return keys
    }()
}
