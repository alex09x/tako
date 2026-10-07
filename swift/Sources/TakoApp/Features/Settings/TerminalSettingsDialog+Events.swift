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
    override func flagsChanged(with event: NSEvent) {
        if isRecording {
            recordingHeldModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            needsDisplay = true
        } else {
            super.flagsChanged(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording {
            handleRecordingKey(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isRecording {
            handleRecordingKey(event)
            return
        }

        switch event.keyCode {
        case 126: moveSelection(-1)            // Up
        case 125: moveSelection(1)             // Down
        case 116: moveSelection(-visibleRows) // Page Up
        case 121: moveSelection(visibleRows)  // Page Down
        case 115: scrollTo(0)                 // Home
        case 119: scrollTo(filteredItems.count - 1) // End
        case 36, 76: startRecording()         // Return / Enter
        case 53: withdraw()                    // Esc
        case 48:                               // Tab -> Focus search
            if let field = searchField {
                window?.makeFirstResponder(field)
            }
        case 44:                               // '/' key -> Focus search
            if let field = searchField {
                window?.makeFirstResponder(field)
            }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": startRecording()
            case "d": resetSelected()
            case "/":
                if let field = searchField {
                    window?.makeFirstResponder(field)
                }
            default: break
            }
        }
    }

    private func handleRecordingKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Escape cancels recording
        if event.keyCode == 53 && flags.isEmpty {
            isRecording = false
            statusMessage = "Recording cancelled."
            needsDisplay = true
            return
        }

        // Delete/Backspace clears override
        if (event.keyCode == 51 || event.keyCode == 117) && flags.isEmpty {
            resetSelected()
            isRecording = false
            return
        }

        let key = resolveKey(from: event)
        guard !key.isEmpty else { return }

        let isSpecial = ["return", "tab", "space", "escape", "up", "down", "left", "right"].contains(key)
        guard !flags.isEmpty || isSpecial else { return }

        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        parts.append(key)

        let trigger = parts.joined(separator: "+")
        guard selectedIndex < filteredItems.count else { return }
        let item = filteredItems[selectedIndex]

        KeybindConfigFile.shared.setKeybind(action: item.id, trigger: trigger)
        let formatted = KeybindRegistry.format(trigger: trigger)
        statusMessage = "Updated '\(item.title)' to \(formatted)."
        isRecording = false
        recordingHeldModifiers = []
        needsDisplay = true
    }

    private func resolveKey(from event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 51: return "backspace"
        case 53: return "escape"
        case 117: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return "" }
            let c = chars.first!
            if c == "\r" { return "return" }
            if c == "\t" { return "tab" }
            return String(c)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let card = cardRect
        guard card.contains(pt) else {
            withdraw()
            return
        }

        let startY = cell(0, 5).y
        let rowHeight = cellHeight
        if pt.y >= startY && pt.y < startY + CGFloat(visibleRows) * rowHeight {
            let clickedVisible = Int((pt.y - startY) / rowHeight)
            let targetIdx = scrollOffset + clickedVisible
            if targetIdx < filteredItems.count {
                selectedIndex = targetIdx
                if event.clickCount == 2 {
                    startRecording()
                } else {
                    needsDisplay = true
                }
            }
        }
    }

    func moveSelection(_ delta: Int) {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), filteredItems.count - 1)
        if selectedIndex < scrollOffset {
            scrollOffset = selectedIndex
        } else if selectedIndex >= scrollOffset + visibleRows {
            scrollOffset = selectedIndex - visibleRows + 1
        }
        needsDisplay = true
    }

    func scrollTo(_ target: Int) {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = min(max(target, 0), filteredItems.count - 1)
        scrollOffset = max(0, min(selectedIndex, filteredItems.count - visibleRows))
        needsDisplay = true
    }

    func startRecording() {
        guard selectedIndex < filteredItems.count else { return }
        isRecording = true
        recordingHeldModifiers = []
        statusMessage = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func resetSelected() {
        guard selectedIndex < filteredItems.count else { return }
        let item = filteredItems[selectedIndex]
        KeybindConfigFile.shared.removeKeybind(action: item.id)
        statusMessage = "Reset '\(item.title)' to default."
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if delta > 0 {
            scrollOffset = max(scrollOffset - 1, 0)
        } else if delta < 0 {
            scrollOffset = min(scrollOffset + 1, max(filteredItems.count - visibleRows, 0))
        }
        needsDisplay = true
    }

    // MARK: - NSTextFieldDelegate (Search)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = searchField else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter {
                $0.title.lowercased().contains(query) ||
                $0.id.lowercased().contains(query) ||
                KeybindRegistry.format(shortcut: KeybindRegistry.defaultShortcut(for: $0.id) ?? .init(" ", modifiers: [])).lowercased().contains(query)
            }
        }
        selectedIndex = 0
        scrollOffset = 0
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(moveDown(_:)) {
            window?.makeFirstResponder(self)
            moveSelection(1)
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            window?.makeFirstResponder(self)
            startRecording()
            return true
        }
        return false
    }
}
