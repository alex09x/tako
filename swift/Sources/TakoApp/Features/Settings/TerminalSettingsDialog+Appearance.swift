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
    var settingsTitle: String { String((presetEditor.map { "Theme: \($0.name)" } ?? scopedAppearance?.title ?? "Tako Settings").prefix(54)) }
    var availableTabs: [SettingsTab] {
        if presetEditor != nil { return [.terminalSettings, .themes, .fonts, .fontSize, .themeConfig] }
        return scopedAppearance == nil ? [.keybindings, .terminalSettings, .themes] : [.themes]
    }
    var inheritanceTitle: String {
        if let scope = scopedAppearance?.scope, case .pane = scope { return "Inherit workspace" }
        return "Inherit Tako settings"
    }

    func updateAppearanceBackdrop() {
        let alpha: CGFloat = presetEditor != nil || activeTab == .themes ? 0.12 : 0.65
        layer?.backgroundColor = TakoTUI.deep.withAlphaComponent(alpha).cgColor
    }

    func inheritanceItem(key: String, category: String) -> TerminalSettingItem {
        TerminalSettingItem(id: key, title: inheritanceTitle, category: category,
                            type: .options(options: [], defaultValue: ""),
                            description: "Remove this override and follow the parent style")
    }

    func storedSettingValue(for item: TerminalSettingItem) -> String? {
        if let presetEditor { return presetEditor.value(for: item.id) }
        if let scopedAppearance { return scopedAppearance.value(for: item.id) }
        return configFile.getSettingValue(for: item)
    }

    func effectiveSettingValue(for item: TerminalSettingItem) -> String {
        if let presetEditor { return presetEditor.effectiveValue(for: item.id) }
        if let scopedAppearance { return scopedAppearance.effectiveValue(for: item.id) ?? item.type.defaultStringValue }
        return configFile.effectiveSettingValue(for: item)
    }

    @discardableResult func setSettingValue(_ value: String, for item: TerminalSettingItem) -> Bool {
        if let presetEditor { presetEditor.setValue(value, for: item.id); previewEditedTheme(); return true }
        if let scopedAppearance { return scopedAppearance.setValue(value, for: item.id) }
        return configFile.setSettingValue(value, for: item)
    }

    @discardableResult func removeSettingValue(for item: TerminalSettingItem) -> Bool {
        if let presetEditor { presetEditor.reset(item.id); previewEditedTheme(); return true }
        if item.id == "theme" { return inheritTheme() }
        if let scopedAppearance { return scopedAppearance.setValue(nil, for: item.id) }
        return configFile.removeSettingValue(for: item)
    }

    private func inheritTheme() -> Bool {
        guard let scopedAppearance else { return applyCompleteTheme("TakoCore") }
        guard scopedAppearance.isAvailable() else { return false }
        do { try scopedAppearance.store.reset(scopedAppearance.scope); return true }
        catch { statusMessage = error.localizedDescription; return false }
    }

    /// Only explicit user selection applies choices. Catalog construction and
    /// search filtering must never write settings or replace the active theme.
    func applySelectedAppearanceImmediately() {
        guard activeTab == .themes && presetEditor == nil || activeTab == .fonts && presetEditor != nil else { return }
        guard selectedSettingIndex < filteredSettingItems.count else { return }
        let item = filteredSettingItems[selectedSettingIndex]
        guard item.category == TerminalAppearanceCatalog.themeCategory
                || item.category == TerminalAppearanceCatalog.fontCategory else { return }
        applyAppearanceChoice(item)
    }

    func previewEditedTheme() {
        guard let editor = presetEditor, let theme = try? editor.validatedTheme() else { return }
        _ = editor.preview?.apply(theme)
    }

    func isActiveAppearanceChoice(_ item: TerminalSettingItem) -> Bool {
        let raw = storedSettingValue(for: item)
        if let scopedAppearance, item.title == inheritanceTitle {
            return item.id == "theme" ? scopedAppearance.store.document.overrides(for: scopedAppearance.scope)?.isEmpty != false : raw == nil
        }
        let fallback = item.id == "theme" ? "TakoCore" : TerminalAppearanceCatalog.defaultFont
        guard let selected = raw ?? (scopedAppearance == nil ? fallback : nil) else { return false }
        return selected.caseInsensitiveCompare(item.title) == .orderedSame
            || (item.id == "theme" && selected.lowercased() == "tako" && item.title == "TakoCore")
    }

    func applyCompleteTheme(_ name: String) -> Bool {
        guard (try? ThemePresetStore.validatePresetName(name)) != nil else { return false }
        if let scopedAppearance {
            guard scopedAppearance.isAvailable() else { return false }
            do {
                try scopedAppearance.store.applyPreset(name, scope: scopedAppearance.scope)
                return true
            } catch { statusMessage = error.localizedDescription; return false }
        }
        return configFile.applyFullThemePreset(name)
    }

    func appearanceChoiceFont(for item: TerminalSettingItem) -> NSFont? {
        guard item.category == TerminalAppearanceCatalog.fontCategory else { return nil }
        if let scopedAppearance, item.title == inheritanceTitle {
            return Style.from(scopedAppearance.previewInheriting("font-family")).font
        }
        return NSFontManager.shared.font(withFamily: item.title, traits: [], weight: 5, size: style.font.pointSize)
    }
}
