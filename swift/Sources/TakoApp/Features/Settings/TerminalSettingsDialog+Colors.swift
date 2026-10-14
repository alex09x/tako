/*
 * tako — In-terminal color editing
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension TerminalSettingsDialog {
    func beginEditingColor(_ item: TerminalSettingItem) {
        cancelEditingColor()
        let field = NSTextField(string: configFile.effectiveSettingValue(for: item))
        field.font = style.boldFont
        field.textColor = TakoTUI.bright
        field.backgroundColor = TakoTUI.field
        field.isBordered = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityIdentifier("terminal-setting-color-" + item.id)
        field.setAccessibilityLabel(item.title + " HEX color")
        colorEditField = field
        colorEditItem = item
        addSubview(field)
        layoutColorEditor()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        statusMessage = "Color: #RRGGBB · Return saves · Esc cancels"
        needsDisplay = true
    }

    func layoutColorEditor() {
        guard let field = colorEditField, let item = colorEditItem,
              let index = filteredSettingItems.firstIndex(where: { $0.id == item.id }) else { return }
        let point = cell(46, 5 + index - scrollSettingOffset)
        field.frame = NSRect(x: point.x, y: point.y, width: 12 * cellWidth, height: cellHeight)
    }

    func saveEditedColor() {
        guard let field = colorEditField, let item = colorEditItem else { return }
        var value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            statusMessage = "Invalid color. Enter six HEX digits, e.g. #5fafff."
            setAccessibilityValue("setting_color_invalid: " + item.id)
            needsDisplay = true
            return
        }
        value = "#" + value.lowercased()
        guard configFile.setSettingValue(value, for: item) else {
            statusMessage = "Could not save color. Your config was not updated."
            setAccessibilityValue("setting_write_error: " + item.id)
            needsDisplay = true
            return
        }
        cancelEditingColor()
        Tako.TabBarController.refreshAll()
        statusMessage = "Saved: " + item.id + " = " + value
        updateAccessibilityState()
        setAccessibilityValue("setting_custom_success: " + item.id)
        needsDisplay = true
    }

    func cancelEditingColor(restoreFocus: Bool = true) {
        guard let field = colorEditField else { return }
        colorEditField = nil
        colorEditItem = nil
        statusMessage = nil
        if restoreFocus {
            window?.makeFirstResponder(self)
        }
        field.removeFromSuperview()
        needsDisplay = true
    }
}
