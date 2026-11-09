/*
 * tako — Live, validated persistence of registry settings from native settings
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Reads and writes the real configuration file through KeybindConfigFile.
/// Every write reports its actual outcome; nothing is assumed to succeed.
@MainActor
final class DesktopPreferenceStore: ObservableObject {
    let configFile: KeybindConfigFile
    @Published private(set) var lastError: String?
    @Published private(set) var revision = 0

    init(configFile: KeybindConfigFile) {
        self.configFile = configFile
    }

    /// The family is chosen from the installed inventory rather than a fixed option list.
    static let fontFamilyItem = TerminalSettingItem(id: "font-family", title: "Font Family", category: "Appearance",
                                                    type: .options(options: [], defaultValue: ""),
                                                    description: "Terminal font family")

    static func item(_ key: String) -> TerminalSettingItem? {
        key == "font-family" ? fontFamilyItem : TerminalSettingRegistry.setting(for: key)
    }

    /// Value written in the config file, or nil when the default applies.
    func localValue(_ key: String) -> String? {
        Self.item(key).flatMap { configFile.getSettingValue(for: $0) }
    }

    func isOverridden(_ key: String) -> Bool { localValue(key) != nil }

    func value(_ key: String) -> String {
        guard let item = Self.item(key) else { return "" }
        return configFile.getSettingValue(for: item) ?? item.type.defaultStringValue
    }

    func bool(_ key: String) -> Bool { value(key).lowercased() == "true" }

    /// What the terminal renders for `key`: the config parsed with its theme
    /// resolved, so a full preset's font or size shows even without a raw line.
    func effectiveValue(_ key: String) -> String? {
        if key == "theme" { return localValue(key) ?? "TakoCore" }
        return Self.item(key).map { configFile.effectiveSettingValue(for: $0) }
    }

    /// A full preset (one with typography) drops stale global appearance
    /// lines, as the old settings and `takoctl theme apply` do; a colours-only
    /// preset is just selected and the custom lines stay.
    @discardableResult
    func selectPreset(_ name: String, full: Bool) -> Bool {
        guard full else { return set("theme", name) }
        guard configFile.applyFullThemePreset(name) else {
            return fail("Could not apply theme “\(name)” to \(configFile.configPath ?? "configuration file")")
        }
        return succeed()
    }

    var desktopPreferences: DesktopPreferences {
        DesktopPreferences { [self] key in localValue(key) }
    }

    @discardableResult
    func set(_ key: String, _ value: String) -> Bool {
        guard let item = Self.item(key) else { return fail("Unknown setting: \(key)") }
        if let reason = Self.validationError(value, for: item) { return fail(reason) }
        guard configFile.setSettingValue(value, for: item) else {
            return fail("Could not write \(key) to \(configFile.configPath ?? "configuration file")")
        }
        return succeed()
    }

    @discardableResult
    func reset(_ key: String) -> Bool {
        guard let item = Self.item(key) else { return fail("Unknown setting: \(key)") }
        guard configFile.removeSettingValue(for: item) else {
            return fail("Could not reset \(key)")
        }
        return succeed()
    }

    static func validationError(_ value: String, for item: TerminalSettingItem) -> String? {
        switch item.type {
        case .boolean:
            return ["true", "false"].contains(value) ? nil : "\(item.id): expected true or false"
        case .options(let options, _):
            // The theme list is computed once at launch; any installed name is valid.
            if item.id == "font-family" { return AppearanceValidator.isValidName(value) ? nil : "Invalid font name" }
            guard item.id != "theme" else { return AppearanceValidator.isValidName(value) ? nil : "Invalid theme name" }
            return options.contains(value) ? nil : "\(item.id): invalid value \(value)"
        case .number(_, let min, let max, _):
            // Terminal font size is fractional and spans the renderer's 6…72 range.
            if item.id == "font-size" {
                return AppearanceValidator.isValidFontSize(value) ? nil : "Font size must be between 6 and 72 pt"
            }
            guard let number = Double(value), number >= Double(min), number <= Double(max) else {
                return "\(item.id): value must be between \(min) and \(max)"
            }
            return nil
        case .color:
            return AppearanceValidator.isValidRGBColor(value) ? nil : "\(item.id): expected a color in #rrggbb format"
        }
    }

    private func fail(_ message: String) -> Bool {
        lastError = message
        return false
    }

    private func succeed() -> Bool {
        lastError = nil
        revision += 1
        return true
    }
}
