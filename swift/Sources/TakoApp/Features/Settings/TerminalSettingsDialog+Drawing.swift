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
        let title = "Tako Keybindings & Settings"
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

        // Header columns (Row 4)
        let headerY = 4
        drawText("ACTION", col: 3, row: headerY, font: style.boldFont, color: TakoTUI.dim)
        drawText("SHORTCUT", col: 44, row: headerY, font: style.boldFont, color: TakoTUI.dim)
        drawText("STATUS", col: 58, row: headerY, font: style.boldFont, color: TakoTUI.dim)

        // List Rows (Row 5 to 5 + visibleRows)
        let startRow = 5
        let customOverrides = configFile.customOverrides

        for i in 0..<visibleRows {
            let itemIndex = scrollOffset + i
            let r = startRow + i
            guard itemIndex < filteredItems.count else { break }
            let item = filteredItems[itemIndex]
            let isSelected = itemIndex == selectedIndex

            let rowOrigin = cell(2, r)
            if isSelected {
                TakoTUI.selection.setFill()
                NSRect(x: rowOrigin.x, y: rowOrigin.y, width: CGFloat(columns - 4) * cellWidth, height: cellHeight).fill()
                drawText("▌", col: 2, row: r, font: style.boldFont, color: TakoTUI.ember)
            }

            // Action Title
            let titleColor = isSelected ? TakoTUI.bright : TakoTUI.text
            let titleText = String(item.title.prefix(38))
            drawText(titleText, col: 4, row: r, font: isSelected ? style.boldFont : style.font, color: titleColor)

            // Current Shortcut
            let shortcutDisplay: String
            let isCustom = customOverrides[item.id] != nil
            if let customTrigger = customOverrides[item.id] {
                shortcutDisplay = KeybindRegistry.format(trigger: customTrigger)
            } else if let def = KeybindRegistry.defaultShortcut(for: item.id) {
                shortcutDisplay = KeybindRegistry.format(shortcut: def)
            } else {
                shortcutDisplay = "—"
            }

            let scColor = isCustom ? TakoTUI.ember : (isSelected ? TakoTUI.claw : TakoTUI.soft)
            drawText(shortcutDisplay, col: 44, row: r, font: style.boldFont, color: scColor)

            // Status Tag
            let statusText = isCustom ? "[custom]" : "default"
            let statusColor = isCustom ? TakoTUI.ember : TakoTUI.dim
            drawText(statusText, col: 58, row: r, font: style.font, color: statusColor)
        }

        // Scrollbar track
        if filteredItems.count > visibleRows {
            let trackY = cell(0, startRow).y
            let trackHeight = CGFloat(visibleRows) * cellHeight
            let track = NSRect(x: card.maxX - cellWidth / 2 - 1.5, y: trackY, width: 3, height: trackHeight)
            let thumbHeight = max(trackHeight * CGFloat(visibleRows) / CGFloat(filteredItems.count), cellHeight)
            let maxOffset = filteredItems.count - visibleRows
            let thumbY = track.minY + (trackHeight - thumbHeight) * CGFloat(scrollOffset) / CGFloat(maxOffset)
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
        } else {
            let hint = "↑↓ navigate · return/R record · D reset · / search · esc close"
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
