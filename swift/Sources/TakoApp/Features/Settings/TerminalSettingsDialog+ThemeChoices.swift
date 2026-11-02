/*
 * tako — Accessible, immediate theme preset choices
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension TerminalSettingsDialog {
    func layoutThemeChoices() {
        guard activeTab == .themes, presetEditor == nil else {
            themeChoiceButtons.forEach { $0.removeFromSuperview() }
            themeChoiceButtons.removeAll()
            return
        }
        let indices = Array(filteredSettingItems.indices.dropFirst(scrollSettingOffset).prefix(visibleRows))
        while themeChoiceButtons.count > indices.count { themeChoiceButtons.removeLast().removeFromSuperview() }
        while themeChoiceButtons.count < indices.count {
            let button = NSButton(title: "", target: self, action: #selector(themeChoicePressed(_:)))
            button.isBordered = false
            button.isTransparent = true
            button.setAccessibilityRole(.button)
            addSubview(button)
            themeChoiceButtons.append(button)
        }
        for (row, index) in indices.enumerated() {
            let item = filteredSettingItems[index]
            let button = themeChoiceButtons[row]
            button.tag = index
            button.setAccessibilityLabel(item.title)
            button.setAccessibilityIdentifier("ThemePresetChoice-" + item.title)
            button.setAccessibilityValue(isActiveAppearanceChoice(item) ? "Selected" : "")
            let point = cell(2, 5 + row)
            button.frame = NSRect(x: point.x, y: point.y, width: CGFloat(columns - 4) * cellWidth, height: cellHeight)
        }
    }

    @objc private func themeChoicePressed(_ sender: NSButton) {
        guard presetEditor == nil, activeTab == .themes, filteredSettingItems.indices.contains(sender.tag) else { return }
        cancelEditingColor()
        pendingConflict = nil
        selectedSettingIndex = sender.tag
        isTabBarFocused = false
        window?.makeFirstResponder(self)
        applyAppearanceChoice(filteredSettingItems[sender.tag])
    }
}
