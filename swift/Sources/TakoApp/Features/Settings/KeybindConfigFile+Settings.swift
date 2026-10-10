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

extension KeybindConfigFile {
    public static func parseConfigKeyValue(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        var val = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
            val = String(val.dropFirst().dropLast())
        }
        return (key, val)
    }

    public func getSettingValue(for setting: TerminalSettingItem) -> String? {
        let keysToCheck = [setting.id] + setting.aliases
        for line in rawConfigLines.reversed() {
            guard let parsed = Self.parseConfigKeyValue(line) else { continue }
            if keysToCheck.contains(parsed.key) {
                return parsed.value
            }
        }
        return nil
    }

    public func effectiveSettingValue(for setting: TerminalSettingItem) -> String {
        getSettingValue(for: setting) ?? setting.type.defaultStringValue
    }

    @discardableResult
    public func setSettingValue(_ value: String, for setting: TerminalSettingItem) -> Bool {
        guard let path = configPath else { return false }
        do {
            try ensureConfigFileExists(at: path)
            let content = try String(contentsOfFile: path, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            let keysToCheck = [setting.id] + setting.aliases
            var replaced = false
            let newLine = "\(setting.id) = \(value)"

            for i in (0..<lines.count).reversed() {
                guard let parsed = Self.parseConfigKeyValue(lines[i]) else { continue }
                if keysToCheck.contains(parsed.key) {
                    if !replaced {
                        lines[i] = newLine
                        replaced = true
                    } else {
                        lines.remove(at: i)
                    }
                }
            }

            if !replaced {
                if let lastNonEmpty = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    lines.insert(newLine, at: lastNonEmpty + 1)
                } else {
                    lines.append(newLine)
                }
            }

            try saveLinesAndReload(lines, to: path)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func removeSettingValue(for setting: TerminalSettingItem) -> Bool {
        guard let path = configPath else { return true }
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            let keysToCheck = [setting.id] + setting.aliases
            lines.removeAll { line in
                guard let parsed = Self.parseConfigKeyValue(line) else { return false }
                return keysToCheck.contains(parsed.key)
            }
            try saveLinesAndReload(lines, to: path)
            return true
        } catch {
            return false
        }
    }
}
