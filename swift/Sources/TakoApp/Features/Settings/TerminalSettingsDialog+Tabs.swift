/*
 * tako — Terminal settings navigation
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension TerminalSettingsDialog {
    var tabLayout: [(tab: SettingsTab, label: String, column: Int)] {
        let labels = [" [1] Keys", presetEditor == nil ? " [2] General" : " [2] Layout", presetEditor == nil ? " [3] Themes" : " [3] Colors",
                      " [4] Fonts", " [5] Font Size", " [6] Config"]
        var column = 3
        return zip(SettingsTab.allCases, labels).filter { availableTabs.contains($0.0) }.map { tab, label in
            defer { column += label.count + 1 }
            return (tab, label, column)
        }
    }

    func switchTab(to tab: SettingsTab) {
        guard availableTabs.contains(tab) else { return }
        cancelEditingColor()
        guard activeTab != tab else { return }
        activeTab = tab
        pendingConflict = nil
        isRecording = false
        statusMessage = nil
        themeWarning = nil
        updateButtonsForActiveTab()
        filterItems(searchField?.stringValue ?? "")
        updatePresetControlVisibility()
        if presetEditor != nil {
            window?.makeFirstResponder(activeTab == .themeConfig ? presetConfigText : self)
        }
        needsLayout = true
        needsDisplay = true
    }

    func applyAppearanceChoice(_ item: TerminalSettingItem) {
        let isDefaultFont = item.category == TerminalAppearanceCatalog.fontCategory
            && item.title == TerminalAppearanceCatalog.defaultFont
        let isInherited = scopedAppearance != nil && item.title == inheritanceTitle
        let fullPreset = item.id == "theme" && !isInherited
            && TerminalTheme.presetContainsTypography(named: item.title, searchPaths: configFile.appearanceThemePaths)
        let saved = isDefaultFont || isInherited ? removeSettingValue(for: item)
            : fullPreset ? applyCompleteTheme(item.title) : setSettingValue(item.title, for: item)
        if saved {
            if item.category == TerminalAppearanceCatalog.themeCategory { themeWarning = nil }
            statusMessage = item.category == TerminalAppearanceCatalog.themeCategory
                ? "Theme: \(item.title) · \(fullPreset ? "colors and fonts applied" : "custom colors remain")" : "Font: \(item.title)"
            setAccessibilityValue("setting_custom_success: \(item.id) = \(item.title)")
        } else {
            statusMessage = scopedAppearance?.writeError ?? "Could not save \(item.id). Your config was not updated."
            setAccessibilityValue("setting_write_error: \(item.id)")
        }
        needsLayout = true
        needsDisplay = true
    }

    func updateAccessibilityState() {
        if activeTab == .themes && presetEditor == nil { needsLayout = true }
        if isWithdrawing { setAccessibilityValue("closed"); return }
        if isRecording { setAccessibilityValue("recording"); return }
        if let msg = statusMessage { setAccessibilityValue(msg); return }
        if activeTab == .keybindings {
            let item = selectedIndex < filteredItems.count ? filteredItems[selectedIndex].title : "No matching actions"
            setAccessibilityValue("Keybindings: \(filteredItems.count) items, \(item)")
        } else {
            let item = selectedSettingIndex < filteredSettingItems.count ? filteredSettingItems[selectedSettingIndex].title : "No matching settings"
            let warning = activeTab == .themes ? themeWarning.map { "; \($0)" } ?? "" : ""
            let detail = (scopedAppearance != nil || presetEditor != nil) && selectedSettingIndex < filteredSettingItems.count
                ? " = " + effectiveSettingValue(for: filteredSettingItems[selectedSettingIndex]) : ""
            let section = presetEditor != nil && activeTab == .themes ? "Colors"
                : presetEditor != nil && activeTab == .terminalSettings ? "Layout" : activeTab.title
            setAccessibilityValue("\(section): \(filteredSettingItems.count) items, \(item)\(detail)\(warning)")
        }
    }

    func filterItems(_ query: String) {
        cancelEditingColor(restoreFocus: false)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if activeTab == .keybindings {
            filteredItems = q.isEmpty ? allItems : allItems.filter { item in
                item.title.localizedCaseInsensitiveContains(q) || item.id.localizedCaseInsensitiveContains(q)
                    || (configFile.customOverrides[item.id]?.localizedCaseInsensitiveContains(q) ?? false)
                    || (KeybindRegistry.defaultShortcut(for: item.id).map { KeybindRegistry.format(shortcut: $0) }?.localizedCaseInsensitiveContains(q) ?? false)
            }
            selectedIndex = 0
            scrollOffset = 0
        } else {
            let items: [TerminalSettingItem]
            switch activeTab {
            case .themes:
                if presetEditor != nil {
                    themeWarning = nil
                    items = ThemePresetEditor.colorItems
                    break
                }
                let names = TerminalAppearanceCatalog.themeNames(paths: configFile.appearanceThemePaths)
                if let themeSetting = TerminalSettingRegistry.setting(for: "theme"),
                   let selected = storedSettingValue(for: themeSetting), selected.lowercased() != "tako",
                   !names.contains(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) {
                    themeWarning = "Theme unavailable: \(selected). Choose an installed preset."
                } else {
                    themeWarning = nil
                }
                let presets = TerminalAppearanceCatalog.themeItems(names)
                items = scopedAppearance == nil ? presets : [inheritanceItem(key: "theme", category: TerminalAppearanceCatalog.themeCategory)] + presets
            case .fonts:
                if fontFamilies.isEmpty { fontFamilies = TerminalAppearanceCatalog.fontFamilies() }
                items = presetEditor != nil
                    ? TerminalAppearanceCatalog.fontItems(fontFamilies).filter { $0.title != TerminalAppearanceCatalog.defaultFont }
                    : scopedAppearance == nil ? TerminalAppearanceCatalog.fontItems(fontFamilies)
                    : [inheritanceItem(key: "font-family", category: TerminalAppearanceCatalog.fontCategory)]
                        + TerminalAppearanceCatalog.fontItems(fontFamilies).filter { $0.title != TerminalAppearanceCatalog.defaultFont }
            case .fontSize: items = TerminalAppearanceCatalog.sizeItems
            case .themeConfig: items = []
            case .terminalSettings:
                items = allSettingItems.filter { item in
                    let appearance = ThemePresetConfig.isAppearanceKey(item.id)
                    if presetEditor != nil {
                        return appearance && !["font-family", "font-size"].contains(item.id)
                            && !TerminalSettingRegistry.colorSettings.contains(where: { $0.id == item.id })
                    }
                    return !appearance && item.id != "theme"
                }
            case .keybindings: items = allSettingItems
            }
            filteredSettingItems = q.isEmpty ? items : items.filter { item in
                item.title.localizedCaseInsensitiveContains(q) || item.id.localizedCaseInsensitiveContains(q)
                    || item.category.localizedCaseInsensitiveContains(q) || item.description.localizedCaseInsensitiveContains(q)
                    || item.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
            }
            selectedSettingIndex = activeTab == .themes && presetEditor == nil
                ? filteredSettingItems.firstIndex(where: isActiveAppearanceChoice) ?? 0 : 0
            scrollSettingOffset = max(0, selectedSettingIndex - visibleRows + 1)
        }
        needsDisplay = true
        updatePresetControlVisibility()
        updateAccessibilityState()
    }
}
