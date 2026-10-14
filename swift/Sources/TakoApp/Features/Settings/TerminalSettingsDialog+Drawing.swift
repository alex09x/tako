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

extension TerminalSettingsDialog {
    override func draw(_ dirtyRect: NSRect) {
        let card = cardRect
        style.background.setFill()
        card.fill()

        let gradient = NSGradient(starting: style.accent, ending: style.accentEnd)
        func shade(_ col: Int) -> NSColor {
            gradient?.interpolatedColor(atLocation: CGFloat(col) / CGFloat(max(columns - 1, 1))) ?? style.accent
        }

        // Frame
        let inset = NSRect(x: card.minX + cellWidth / 2, y: card.minY + cellHeight / 2,
                           width: card.width - cellWidth, height: card.height - cellHeight)
        let radius = min(cellWidth, cellHeight) / 2
        let frame = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let stroke = frame.cgPath.copy(strokingWithWidth: 1.25, lineCap: .butt, lineJoin: .round, miterLimit: 1)
        NSBezierPath(cgPath: stroke).addClip()
        gradient?.draw(in: card, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        // Title and Hatching
        let title = "Tako Settings"
        let gap = cell(2, 0)
        style.background.setFill()
        NSRect(x: gap.x, y: gap.y, width: CGFloat(columns - 4) * cellWidth, height: cellHeight).fill()
        drawText(title, col: 3, row: 0, font: style.boldFont, color: TakoTUI.claw)
        let hatchStart = 3 + title.count + 2
        if hatchStart < columns - 2 {
            for c in hatchStart..<(columns - 2) {
                drawText("╱", col: c, row: 0, font: style.font, color: shade(c))
            }
        }

        // Tabs (Row 1): [1] Keybindings  [2] Terminal Settings
        let tab1Title = " [1] Keybindings "
        let tab2Title = " [2] Terminal Settings "
        let tab1Col = 3
        let tab2Col = tab1Col + tab1Title.count + 2

        let tab1Selected = activeTab == .keybindings
        let tab2Selected = activeTab == .terminalSettings

        let tab1Origin = cell(tab1Col, 1)
        if tab1Selected {
            let tab1Rect = NSRect(x: tab1Origin.x, y: tab1Origin.y, width: CGFloat(tab1Title.count) * cellWidth, height: cellHeight)
            TakoTUI.selection.setFill()
            tab1Rect.fill()
            if isTabBarFocused {
                drawText("▌", col: tab1Col - 1, row: 1, font: style.boldFont, color: TakoTUI.ember)
            }
        }
        drawText(tab1Title, col: tab1Col, row: 1, font: tab1Selected ? style.boldFont : style.font,
                 color: tab1Selected ? (isTabBarFocused ? TakoTUI.bright : TakoTUI.text) : TakoTUI.dim)

        let tab2Origin = cell(tab2Col, 1)
        if tab2Selected {
            let tab2Rect = NSRect(x: tab2Origin.x, y: tab2Origin.y, width: CGFloat(tab2Title.count) * cellWidth, height: cellHeight)
            TakoTUI.selection.setFill()
            tab2Rect.fill()
            if isTabBarFocused {
                drawText("▌", col: tab2Col - 1, row: 1, font: style.boldFont, color: TakoTUI.ember)
            }
        }
        drawText(tab2Title, col: tab2Col, row: 1, font: tab2Selected ? style.boldFont : style.font,
                 color: tab2Selected ? (isTabBarFocused ? TakoTUI.bright : TakoTUI.text) : TakoTUI.dim)

        // Header columns (Row 4)
        let headerY = 4
        if activeTab == .keybindings {
            drawText("ACTION", col: 4, row: headerY, font: style.boldFont, color: TakoTUI.dim)
            drawText("SHORTCUT", col: 46, row: headerY, font: style.boldFont, color: TakoTUI.dim)
        } else {
            drawText("SETTING", col: 4, row: headerY, font: style.boldFont, color: TakoTUI.dim)
            drawText("VALUE", col: 46, row: headerY, font: style.boldFont, color: TakoTUI.dim)
        }

        // List Rows (Row 5 to 5 + visibleRows)
        let startRow = 5

        if activeTab == .keybindings {
            let customOverrides = configFile.customOverrides
            for i in 0..<visibleRows {
                let itemIndex = scrollOffset + i
                let r = startRow + i
                guard itemIndex < filteredItems.count else { break }
                let item = filteredItems[itemIndex]
                let isSelected = itemIndex == selectedIndex

                let rowOrigin = cell(2, r)
                if isSelected {
                    if isTabBarFocused {
                        TakoTUI.selection.withAlphaComponent(0.4).setFill()
                        NSRect(x: rowOrigin.x, y: rowOrigin.y, width: CGFloat(columns - 4) * cellWidth, height: cellHeight).fill()
                    } else {
                        TakoTUI.selection.setFill()
                        NSRect(x: rowOrigin.x, y: rowOrigin.y, width: CGFloat(columns - 4) * cellWidth, height: cellHeight).fill()
                        drawText("▌", col: 2, row: r, font: style.boldFont, color: TakoTUI.ember)
                    }
                }

                // Action Title
                let titleColor = isSelected ? (isTabBarFocused ? TakoTUI.text : TakoTUI.bright) : TakoTUI.text
                let titleText = String(item.title.prefix(40))
                drawText(titleText, col: 4, row: r, font: isSelected ? style.boldFont : style.font, color: titleColor)

                // Current Shortcut
                let shortcutDisplay: String
                let customTrigger = customOverrides[item.id]
                let defaultShortcut = KeybindRegistry.defaultShortcut(for: item.id)
                let isCustom: Bool
                if let customTrigger = customTrigger {
                    if let def = defaultShortcut {
                        let defTrigger = KeybindRegistry.trigger(for: def)
                        isCustom = KeybindRegistry.normalizeTrigger(customTrigger) != KeybindRegistry.normalizeTrigger(defTrigger)
                    } else {
                        isCustom = true
                    }
                    shortcutDisplay = KeybindRegistry.format(trigger: customTrigger)
                } else if let def = defaultShortcut {
                    shortcutDisplay = KeybindRegistry.format(shortcut: def)
                    isCustom = false
                } else {
                    shortcutDisplay = "—"
                    isCustom = false
                }

                let scColor = isCustom ? TakoTUI.ember : (isSelected && !isTabBarFocused ? TakoTUI.claw : TakoTUI.soft)
                drawText(shortcutDisplay, col: 46, row: r, font: style.boldFont, color: scColor)
            }
        } else {
            for i in 0..<visibleRows {
                let itemIndex = scrollSettingOffset + i
                let r = startRow + i
                guard itemIndex < filteredSettingItems.count else { break }
                let item = filteredSettingItems[itemIndex]
                let isSelected = itemIndex == selectedSettingIndex

                let rowOrigin = cell(2, r)
                if isSelected {
                    if isTabBarFocused {
                        TakoTUI.selection.withAlphaComponent(0.4).setFill()
                        NSRect(x: rowOrigin.x, y: rowOrigin.y, width: CGFloat(columns - 4) * cellWidth, height: cellHeight).fill()
                    } else {
                        TakoTUI.selection.setFill()
                        NSRect(x: rowOrigin.x, y: rowOrigin.y, width: CGFloat(columns - 4) * cellWidth, height: cellHeight).fill()
                        drawText("▌", col: 2, row: r, font: style.boldFont, color: TakoTUI.ember)
                    }
                }

                // Setting Title
                let titleColor = isSelected ? (isTabBarFocused ? TakoTUI.text : TakoTUI.bright) : TakoTUI.text
                let titleText = String(item.title.prefix(40))
                drawText(titleText, col: 4, row: r, font: isSelected ? style.boldFont : style.font, color: titleColor)

                // Current Value
                let displayVal = configFile.effectiveSettingValue(for: item)
                if case .color = item.type, let cg = TerminalTheme.parseColor(displayVal) {
                    NSColor(cgColor: cg)?.setFill()
                    let point = cell(44, r)
                    NSRect(x: point.x, y: point.y + 3, width: cellWidth, height: cellHeight - 6).fill()
                }
                let isCustom = configFile.getSettingValue(for: item) != nil
                let valColor = isCustom ? TakoTUI.ember : (isSelected && !isTabBarFocused ? TakoTUI.claw : TakoTUI.soft)
                drawText(displayVal, col: 46, row: r, font: style.boldFont, color: valColor)
            }
        }

        // Scrollbar track
        let currentItemCount = activeTab == .keybindings ? filteredItems.count : filteredSettingItems.count
        let currentOffset = activeTab == .keybindings ? scrollOffset : scrollSettingOffset
        if currentItemCount > visibleRows {
            let trackY = cell(0, startRow).y
            let trackHeight = CGFloat(visibleRows) * cellHeight
            let track = NSRect(x: card.maxX - cellWidth / 2 - 1.5, y: trackY, width: 3, height: trackHeight)
            let thumbHeight = max(trackHeight * CGFloat(visibleRows) / CGFloat(currentItemCount), cellHeight)
            let maxOffset = currentItemCount - visibleRows
            let thumbY = track.minY + (trackHeight - thumbHeight) * CGFloat(currentOffset) / CGFloat(maxOffset)
            TakoTUI.ember.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: thumbY, width: track.width, height: thumbHeight),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Bottom Banner / Hint
        let bottomRow = totalRows - 2
        if let conflict = pendingConflict {
            let formatted = KeybindRegistry.format(trigger: conflict.trigger)
            let shortConflict = String(conflict.conflictingItem.title.prefix(18))
            let msg = "⚠️ Conflict: \(formatted) used by '\(shortConflict)'. Overwrite? (Return=Yes, Esc=No)"
            drawText(msg, col: 3, row: bottomRow, font: style.boldFont, color: TakoTUI.ember)
        } else if isRecording {
            let held = formatHeldModifiers(recordingHeldModifiers)
            let prompt = held.isEmpty
                ? "RECORDING: Press shortcut keys on keyboard… (Esc to cancel)"
                : "RECORDING: \(held) + … (release or press key)"
            drawText(prompt, col: 3, row: bottomRow, font: style.boldFont, color: TakoTUI.claw)
        } else if let status = statusMessage {
            drawText(status, col: 3, row: bottomRow, font: style.font, color: TakoTUI.claw)
        } else if activeTab == .keybindings {
            let hint = "↑↓ navigate · return/R record · D reset · 1/2 tabs · / search · esc close"
            drawText(hint, col: 3, row: bottomRow, font: style.font, color: style.muted)
        } else {
            let hint = "↑↓ navigate · return edit/toggle · D reset · / search · esc close"
            drawText(hint, col: 3, row: bottomRow, font: style.font, color: style.muted)
        }
    }

    func drawText(_ text: String, col: Int, row: Int, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let pt = cell(col, row)
        let str = text as NSString
        let h = str.size(withAttributes: attrs).height
        str.draw(at: NSPoint(x: pt.x, y: pt.y + (cellHeight - h) / 2), withAttributes: attrs)
    }

    func formatHeldModifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var str = ""
        if flags.contains(.control) { str += "⌃" }
        if flags.contains(.option) { str += "⌥" }
        if flags.contains(.shift) { str += "⇧" }
        if flags.contains(.command) { str += "⌘" }
        return str
    }
}
