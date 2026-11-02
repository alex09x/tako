/*
 * tako — Appearance settings routing
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension TerminalSettingsDialog {
    var settingsTitle: String { String((scopedAppearance?.title ?? "Tako Settings").prefix(54)) }
    var availableTabs: [SettingsTab] { scopedAppearance == nil ? SettingsTab.allCases : [.themes, .fonts, .fontSize] }
    var inheritanceTitle: String {
        if let scope = scopedAppearance?.scope, case .pane = scope { return "Inherit workspace" }
        return "Inherit Tako settings"
    }

    func inheritanceItem(key: String, category: String) -> TerminalSettingItem {
        TerminalSettingItem(id: key, title: inheritanceTitle, category: category,
                            type: .options(options: [], defaultValue: ""),
                            description: "Remove this override and follow the parent style")
    }

    func storedSettingValue(for item: TerminalSettingItem) -> String? {
        if let scopedAppearance { return scopedAppearance.value(for: item.id) }
        return configFile.getSettingValue(for: item)
    }

    func effectiveSettingValue(for item: TerminalSettingItem) -> String {
        if let scopedAppearance { return scopedAppearance.effectiveValue(for: item.id) ?? item.type.defaultStringValue }
        return configFile.effectiveSettingValue(for: item)
    }

    @discardableResult func setSettingValue(_ value: String, for item: TerminalSettingItem) -> Bool {
        if let scopedAppearance { return scopedAppearance.setValue(value, for: item.id) }
        return configFile.setSettingValue(value, for: item)
    }

    @discardableResult func removeSettingValue(for item: TerminalSettingItem) -> Bool {
        if let scopedAppearance { return scopedAppearance.setValue(nil, for: item.id) }
        return configFile.removeSettingValue(for: item)
    }

    func isActiveAppearanceChoice(_ item: TerminalSettingItem) -> Bool {
        let raw = storedSettingValue(for: item)
        if scopedAppearance != nil && item.title == inheritanceTitle { return raw == nil }
        let fallback = item.id == "theme" ? "TakoCore" : TerminalAppearanceCatalog.defaultFont
        guard let selected = raw ?? (scopedAppearance == nil ? fallback : nil) else { return false }
        return selected.caseInsensitiveCompare(item.title) == .orderedSame
            || (item.id == "theme" && selected.lowercased() == "tako" && item.title == "TakoCore")
    }
}
