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
        let labels = [" [1] Keys", " [2] General", " [3] Themes", " [4] Fonts", " [5] Font Size"]
        var column = 3
        return zip(SettingsTab.allCases, labels).map { tab, label in
            defer { column += label.count + 1 }
            return (tab, label, column)
        }
    }

    func switchTab(to tab: SettingsTab) {
        cancelEditingColor()
        guard activeTab != tab else { return }
        activeTab = tab
        pendingConflict = nil
        isRecording = false
        statusMessage = nil
        themeWarning = nil
        updateButtonsForActiveTab()
        filterItems(searchField?.stringValue ?? "")
        needsDisplay = true
    }

    func applyAppearanceChoice(_ item: TerminalSettingItem) {
        let isDefaultFont = item.category == TerminalAppearanceCatalog.fontCategory
            && item.title == TerminalAppearanceCatalog.defaultFont
        let saved = isDefaultFont ? configFile.removeSettingValue(for: item)
                                  : configFile.setSettingValue(item.title, for: item)
        if saved {
            if item.category == TerminalAppearanceCatalog.themeCategory { themeWarning = nil }
            statusMessage = item.category == TerminalAppearanceCatalog.themeCategory
                ? "Theme: \(item.title) · custom colors remain" : "Font: \(item.title)"
            setAccessibilityValue("setting_custom_success: \(item.id) = \(item.title)")
        } else {
            statusMessage = "Could not save \(item.id). Your config was not updated."
            setAccessibilityValue("setting_write_error: \(item.id)")
        }
        needsDisplay = true
    }

    func updateAccessibilityState() {
        if isWithdrawing { setAccessibilityValue("closed"); return }
        if isRecording { setAccessibilityValue("recording"); return }
        if let msg = statusMessage { setAccessibilityValue(msg); return }
        if activeTab == .keybindings {
            let item = selectedIndex < filteredItems.count ? filteredItems[selectedIndex].title : "No matching actions"
            setAccessibilityValue("Keybindings: \(filteredItems.count) items, \(item)")
        } else {
            let item = selectedSettingIndex < filteredSettingItems.count ? filteredSettingItems[selectedSettingIndex].title : "No matching settings"
            let warning = activeTab == .themes ? themeWarning.map { "; \($0)" } ?? "" : ""
            setAccessibilityValue("\(activeTab.title): \(filteredSettingItems.count) items, \(item)\(warning)")
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
                let names = TerminalAppearanceCatalog.themeNames()
                if let themeSetting = TerminalSettingRegistry.setting(for: "theme"),
                   let selected = configFile.getSettingValue(for: themeSetting), selected.lowercased() != "tako",
                   !names.contains(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) {
                    themeWarning = "Theme unavailable: \(selected). Choose an installed preset."
                } else {
                    themeWarning = nil
                }
                items = TerminalAppearanceCatalog.themeItems(names)
            case .fonts:
                if fontFamilies.isEmpty { fontFamilies = TerminalAppearanceCatalog.fontFamilies() }
                items = TerminalAppearanceCatalog.fontItems(fontFamilies)
            case .fontSize: items = TerminalAppearanceCatalog.sizeItems
            case .terminalSettings, .keybindings: items = allSettingItems
            }
            filteredSettingItems = q.isEmpty ? items : items.filter { item in
                item.title.localizedCaseInsensitiveContains(q) || item.id.localizedCaseInsensitiveContains(q)
                    || item.category.localizedCaseInsensitiveContains(q) || item.description.localizedCaseInsensitiveContains(q)
                    || item.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
            }
            selectedSettingIndex = 0
            scrollSettingOffset = 0
        }
        needsDisplay = true
        updateAccessibilityState()
    }
}
