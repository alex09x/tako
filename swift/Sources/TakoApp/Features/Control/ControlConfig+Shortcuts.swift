/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// `takoctl config shortcut`: the Keys section of Settings -- every action
/// with its chord, recorded, cleared and reset the way Settings does it.
extension ControlConfig {
    func shortcut(_ args: [String: JSON]) throws -> [String: JSON] {
        let op = args["op"]?.string ?? "list"
        switch op {
        case "list":
            return ["shortcuts": .array(Self.shortcutActions.map { .object(shortcutEntry($0)) })]
        case "set":
            let action = try Self.shortcutAction(args)
            guard let trigger = args["trigger"]?.string, !trigger.isEmpty,
                  !trigger.contains("\n"), !trigger.contains("="),
                  Tako.MenuShortcutManager.MenuShortcutKey(trigger: trigger) != nil else {
                throw ControlError(.invalid, "\"\(args["trigger"]?.string ?? "")\" is not a key chord (e.g. cmd+shift+k)")
            }
            if args["force"] != .bool(true), let other = file.findConflict(for: trigger, targetAction: action) {
                throw ControlError(.invalid, "\(trigger) already runs \(other.title) (\(other.id)); --force to take it")
            }
            guard file.setKeybind(action: action, trigger: trigger) else { throw writeFailure }
            return shortcutsWritten([action])
        case "unset":
            let action = try Self.shortcutAction(args)
            guard file.removeKeybind(action: action) else { throw writeFailure }
            return shortcutsWritten([action])
        case "reset":
            guard file.resetAllKeybinds() else { throw writeFailure }
            return shortcutsWritten(Self.shortcutActions)
        default:
            throw ControlError(.invalid, "unknown shortcut action \"\(op)\"; use list, set, unset or reset")
        }
    }

    /// Every action Settings lists, once each.
    static var shortcutActions: [String] {
        var seen = Set<String>()
        return KeybindRegistry.allActions.map(\.id).filter { seen.insert(KeybindConfigFile.canonicalActionName($0)).inserted }
    }

    static func shortcutAction(_ args: [String: JSON]) throws -> String {
        guard let name = args["name"]?.string, !name.isEmpty else {
            throw ControlError(.invalid, "name the action, e.g. new_tab or goto_tab:3")
        }
        let canonical = KeybindConfigFile.canonicalActionName(name)
        let known = shortcutActions.contains { KeybindConfigFile.canonicalActionName($0) == canonical }
            || Tako.Config.defaultKeyboardShortcuts[canonical] != nil
        guard known else {
            throw ControlError(.invalid, "unknown action \"\(name)\"; takoctl config shortcut list names them")
        }
        return name
    }

    /// One action: its chord now, whether the user chose it, and Tako's own.
    func shortcutEntry(_ action: String) -> [String: JSON] {
        let item = KeybindRegistry.actionItem(for: action)
        let custom = file.customOverrides[KeybindConfigFile.canonicalActionName(action)]
        let fallback = KeybindRegistry.defaultShortcut(for: action).map(KeybindRegistry.trigger(for:))
        return [
            "action": .string(item.id),
            "title": .string(item.title),
            "category": .string(item.category.rawValue),
            "trigger": (custom ?? fallback).map(JSON.string) ?? .null,
            "custom": .bool(custom != nil),
            "default": fallback.map(JSON.string) ?? .null,
        ]
    }

    private func shortcutsWritten(_ actions: [String]) -> [String: JSON] {
        file.reload()
        return ["shortcuts": .array(actions.map { .object(shortcutEntry($0)) }),
                "errors": .array(Self.errors().map(JSON.string))]
    }

    var writeFailure: ControlError {
        ControlError(.internalError, "could not write \(file.configPath ?? "the config file")")
    }
}
