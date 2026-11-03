/*
 * tako — Discoverable and batch-editable theme settings
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension ThemePresetConfig {
    /// Configuration discovery uses the same validator as the editor/store.
    static let controlKeys = [
        "background", "foreground", "cursor-color", "selection-background", "selection-foreground",
        "font-size", "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic",
        "font-weight", "font-weight-bold", "font-weight-italic", "font-weight-bold-italic",
        "font-style", "font-style-bold", "font-style-italic", "font-style-bold-italic", "font-synthetic-style", "font-feature",
        "adjust-cell-width", "adjust-cell-height", "adjust-font-baseline", "adjust-underline-position", "adjust-underline-thickness",
        "cursor-opacity", "background-opacity", "cursor-thickness", "background-blur", "background-blur-radius",
        "cell-width", "cell_width", "cell-height", "cell_height", "window-padding-x", "window-padding-y",
        "window-padding-balance", "selection-invert-fg-bg", "cursor-style-blink", "window-padding-color", "window-colorspace",
        "cursor-style", "custom-shader", "custom-shader-animation", "palette",
        "tab-status-color-working", "tab-status-color-waiting", "tab-status-color-done", "tab-status-color-error", "tab-status-color-idle"
    ] + (0...255).map { "palette:\($0)" }

    static func updating(_ text: String, settings: [JSON]) throws -> String {
        var updated = text
        var replacedLists = Set<String>()
        for raw in settings {
            guard let pair = raw.object, let rawKey = pair["key"]?.string, let rawValue = pair["value"],
                  isControlFree(rawKey), !rawKey.isEmpty else { throw ControlError(.invalid, "settings must contain key and string/null value") }
            let value: String?
            switch rawValue {
            case .null: value = nil
            case .string(let string) where isControlFree(string): value = string
            default: throw ControlError(.invalid, "setting values must be strings without control characters, or null")
            }
            var key = rawKey
            var settingValue = value
            let aliases = ["background-blur-radius": "background-blur", "cell_width": "cell-width", "cell_height": "cell-height"]
            key = aliases[key] ?? key
            if key == "palette", let value {
                let parts = value.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)), (0...255).contains(index) else {
                    throw ControlError(.invalid, "palette must be INDEX=COLOR, or use palette:INDEX")
                }
                key = "palette:\(index)"; settingValue = String(parts[1])
            }
            guard controlKeys.contains(key) else { throw ControlError(.invalid, "unknown appearance setting: \(key); see theme keys") }
            for alias in aliases.keys where aliases[alias] == key { updated = setting(nil, for: alias, in: updated) }
            if ["font-feature", "custom-shader"].contains(key) {
                if settingValue == nil || replacedLists.insert(key).inserted { updated = removingAll(key, from: updated) }
                if let settingValue { updated += "\n\(key) = \(settingValue)\n" }
            } else if key == "palette" && settingValue == nil {
                updated = removingAll(key, from: updated)
            } else {
                updated = setting(settingValue, for: key, in: updated)
            }
        }
        try validate(prepareForSave(updated))
        return updated
    }

    private static func removingAll(_ key: String, from text: String) -> String {
        text.components(separatedBy: "\n").filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { return true }
            return line[..<equal].trimmingCharacters(in: .whitespaces) != key
        }.joined(separator: "\n")
    }
}
