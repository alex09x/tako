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
import TakoKit

/// `takoctl config`: every setting the config file takes, read and written
/// through the file Settings writes -- the same lines, the same reload.
/// A key Tako does not know is refused, and a setting Settings shows is
/// held to what Settings would let it be.
@MainActor
struct ControlConfig {
    let file: KeybindConfigFile

    /// Keys that may appear many times, each line adding one more.
    static let repeatable: Set<String> = [
        "keybind", "trigger", "palette", "font-feature", "font-family",
        "snapshot-redact-pattern", "snapshot-redaction-pattern", "custom-shader",
    ]

    static var knownKeys: Set<String> {
        knownTakoConfigKeys
            .union(repeatable)
            .union(TerminalSettingRegistry.allSettings.flatMap { [$0.id] + $0.aliases })
    }

    func run(_ args: [String: JSON]) throws -> [String: JSON] {
        let action = args["action"]?.string ?? "list"
        switch action {
        case "path":
            return ["path": file.configPath.map(JSON.string) ?? .null]
        case "list":
            let filter = args["filter"]?.string?.lowercased()
            let keys = Self.knownKeys.sorted().filter { filter == nil || $0.contains(filter!) }
            return ["path": file.configPath.map(JSON.string) ?? .null,
                    "settings": .array(keys.map { .object(entry($0)) })]
        case "get":
            let keys = try Self.keys(args)
            for key in keys { try Self.check(key) }
            return ["settings": .array(keys.map { .object(entry($0)) })]
        case "set", "add":
            let pairs = try Self.pairs(args)
            for (key, value) in pairs {
                try Self.check(key)
                try Self.validate(key, value)
                if action == "add", !Self.repeatable.contains(key) {
                    throw ControlError(.invalid, "\(key) takes one value; use config set")
                }
            }
            for (key, value) in pairs {
                let ok = action == "add" ? append(key, value) : file.setSettingValue(value, for: Self.item(key))
                guard ok else { throw ControlError(.internalError, "could not write \(file.configPath ?? "the config file")") }
            }
            return written(pairs.map(\.0))
        case "unset":
            let keys = try Self.keys(args)
            for key in keys { try Self.check(key) }
            for key in keys where !file.removeSettingValue(for: Self.item(key)) {
                throw ControlError(.internalError, "could not write \(file.configPath ?? "the config file")")
            }
            return written(keys)
        case "shortcut":
            return try shortcut(args)
        case "reload":
            (NSApp?.delegate as? AppDelegate)?.tako.reloadConfig()
            return ["reloaded": .bool(true), "errors": .array(Self.errors().map(JSON.string))]
        default:
            throw ControlError(.invalid, "unknown config action \"\(action)\"; use list, get, set, add, unset, shortcut, path or reload")
        }
    }

    // MARK: reading

    /// One key: what the file sets (every value, for a repeatable key),
    /// whether it is set at all, and what Settings knows of it.
    func entry(_ key: String) -> [String: JSON] {
        let item = TerminalSettingRegistry.setting(for: key)
        var result: [String: JSON] = ["key": .string(item?.id ?? key)]
        if Self.repeatable.contains(key) {
            // Every line, in file order: each one adds.
            let names = Set([key] + (item.map { [$0.id] + $0.aliases } ?? []))
            let values = file.rawConfigLines.compactMap(KeybindConfigFile.parseConfigKeyValue)
                .filter { names.contains($0.key) }.map(\.value)
            result["set"] = .bool(!values.isEmpty)
            result["values"] = .array(values.map(JSON.string))
        } else {
            // Read as Settings reads it: the canonical name wins over an alias.
            let value = file.getSettingValue(for: Self.item(key))
            result["set"] = .bool(value != nil)
            result["value"] = value.map(JSON.string) ?? item.map { .string($0.type.defaultStringValue) } ?? .null
        }
        if let item {
            result["title"] = .string(item.title)
            result["category"] = .string(item.category)
            result["default"] = .string(item.type.defaultStringValue)
            switch item.type {
            case .boolean: result["type"] = .string("boolean")
            case .options(let options, _):
                result["type"] = .string("choice")
                result["options"] = .array(options.map(JSON.string))
            case .number(_, let lo, let hi, _):
                result["type"] = .string("number")
                result["min"] = .number(Double(lo))
                result["max"] = .number(Double(hi))
            case .color: result["type"] = .string("color")
            }
        }
        return result
    }

    private func written(_ keys: [String]) -> [String: JSON] {
        file.reload()
        return ["path": file.configPath.map(JSON.string) ?? .null,
                "settings": .array(keys.map { .object(entry($0)) }),
                "errors": .array(Self.errors().map(JSON.string))]
    }

    static func errors() -> [String] {
        (NSApp?.delegate as? AppDelegate)?.tako.config.errors ?? []
    }

    // MARK: writing

    private func append(_ key: String, _ value: String) -> Bool {
        guard let path = file.configPath else { return false }
        do {
            try file.ensureConfigFileExists(at: path)
            var lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines.append("\(key) = \(value)")
            lines.append("")
            try file.saveLinesAndReload(lines, to: path)
            return true
        } catch {
            return false
        }
    }

    /// The setting Settings shows for `key`, or a plain one for a key it does not.
    static func item(_ key: String) -> TerminalSettingItem {
        DesktopPreferenceStore.item(key)
            ?? TerminalSettingItem(id: key, title: key, category: "", type: .options(options: [], defaultValue: ""))
    }

    // MARK: checking

    static func check(_ key: String) throws {
        guard knownKeys.contains(key) else {
            let near = knownKeys.filter { $0.contains(key) || key.contains($0) }.sorted().prefix(5)
            let hint = near.isEmpty ? "" : "; did you mean \(near.joined(separator: ", "))?"
            throw ControlError(.invalid, "unknown setting \"\(key)\"\(hint)")
        }
    }

    /// A value the file can hold, and for a setting Settings shows, one it
    /// would offer.
    static func validate(_ key: String, _ value: String) throws {
        guard !value.contains("\n"), !value.contains("\r") else {
            throw ControlError(.invalid, "\(key): a value is one line")
        }
        // Exactly what Settings checks before it writes.
        guard let item = DesktopPreferenceStore.item(key) else {
            // Not in Settings, so nothing below checks it. The config parser
            // strips one layer of quotes and drops anything but true/false.
            if key == "bold-is-bright",
               TerminalTheme.parseBool(ThemePresetConfig.unquoted(value)) == nil {
                throw ControlError(.invalid, "\(key): expected true or false")
            }
            return
        }
        if let reason = DesktopPreferenceStore.validationError(value, for: item) {
            throw ControlError(.invalid, reason)
        }
    }

    static func keys(_ args: [String: JSON]) throws -> [String] {
        guard case .array(let items)? = args["keys"], !items.isEmpty else {
            throw ControlError(.invalid, "name at least one setting")
        }
        return try items.map {
            guard let key = $0.string, !key.isEmpty else { throw ControlError(.invalid, "a setting's name is a string") }
            return key
        }
    }

    static func pairs(_ args: [String: JSON]) throws -> [(String, String)] {
        guard case .array(let items)? = args["settings"], !items.isEmpty else {
            throw ControlError(.invalid, "give at least one KEY=VALUE")
        }
        return try items.map { item in
            guard case .object(let pair) = item, let key = pair["key"]?.string, !key.isEmpty,
                  let value = pair["value"]?.string else {
                throw ControlError(.invalid, "each setting is {\"key\": K, \"value\": V}")
            }
            return (key, value.trimmingCharacters(in: .whitespaces))
        }
    }
}
