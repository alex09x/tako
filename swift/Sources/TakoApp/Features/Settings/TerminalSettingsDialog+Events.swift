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

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.isEmpty else {
            return false
        }

        // Allow Cmd+, to toggle/close settings
        if flags == .command && event.charactersIgnoringModifiers == "," {
            withdraw()
            return true
        }

        // Allow Cmd+W to close settings
        if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "w" {
            withdraw()
            return true
        }

        // Allow standard clipboard and text editing shortcuts while searching
        if let field = searchField, window?.firstResponder == field.currentEditor() {
            if flags == .command, let char = event.charactersIgnoringModifiers?.lowercased() {
                if ["a", "c", "v", "x", "z"].contains(char) {
                    return super.performKeyEquivalent(with: event)
                }
            }
        }

        // Modal containment: block all other key equivalents (split, tab, window actions)
        // so they never trigger on the underlying terminal while settings is displayed.
        return true
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
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { break }
            switch chars {
            case "r": startRecording()
            case "d": resetSelected()
            case "/":
                if let field = searchField {
                    window?.makeFirstResponder(field)
                }
            default:
                if let field = searchField, let first = chars.first, (first.isLetter || first.isNumber) {
                    window?.makeFirstResponder(field)
                    field.stringValue += chars
                    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                }
            }
        }
    }

    private func handleRecordingKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Escape cancels recording
        if event.keyCode == 53 && flags.isEmpty {
            isRecording = false
            statusMessage = "Recording cancelled."
            recordingHeldModifiers = []
            needsDisplay = true
            return
        }

        // Delete/Backspace clears override
        if (event.keyCode == 51 || event.keyCode == 117) && flags.isEmpty {
            resetSelected()
            isRecording = false
            recordingHeldModifiers = []
            return
        }

        guard let key = resolveKey(from: event) else { return }

        let isFnKey = (122 == event.keyCode || 120 == event.keyCode || (96...101).contains(event.keyCode) ||
                       103 == event.keyCode || 109 == event.keyCode || 111 == event.keyCode || 118 == event.keyCode)

        // Shortcuts must require at least one modifier key unless it is an explicit function key (F1-F12)
        guard !flags.isEmpty || isFnKey else {
            statusMessage = "Modifier required (⌘, ⌃, ⌥, ⇧ + key). Esc to cancel."
            needsDisplay = true
            return
        }

        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        parts.append(key)

        let trigger = parts.joined(separator: "+")
        guard selectedIndex < filteredItems.count else { return }
        let item = filteredItems[selectedIndex]

        if configFile.setKeybind(action: item.id, trigger: trigger) {
            let formatted = KeybindRegistry.format(trigger: trigger)
            statusMessage = "Updated '\(item.title)' to \(formatted)."
        } else {
            statusMessage = "Error: Failed to write to config file."
        }
        isRecording = false
        recordingHeldModifiers = []
        needsDisplay = true
    }

    private func resolveKey(from event: NSEvent) -> String? {
        if let name = KeybindRegistry.keyName(for: event.keyCode) {
            return name
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
        let c = chars.first!
        return (c.isASCII && (c.isLetter || c.isNumber)) ? String(c) : nil
    }

    // MARK: - Mouse Events (Modal containment)

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard cardRect.contains(pt) else {
            // Modal: clicks on backdrop do not dismiss and do not pass through to terminal
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

    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}

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
        if configFile.removeKeybind(action: item.id) {
            statusMessage = "Reset '\(item.title)' to default."
        } else {
            statusMessage = "Error: Failed to reset config file."
        }
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
        if commandSelector == #selector(moveUp(_:)) {
            window?.makeFirstResponder(self)
            moveSelection(-1)
            return true
        }
        if commandSelector == #selector(pageDown(_:)) {
            window?.makeFirstResponder(self)
            moveSelection(visibleRows)
            return true
        }
        if commandSelector == #selector(pageUp(_:)) {
            window?.makeFirstResponder(self)
            moveSelection(-visibleRows)
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            if let field = searchField, !field.stringValue.isEmpty {
                field.stringValue = ""
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            } else {
                withdraw()
            }
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            window?.makeFirstResponder(self)
            startRecording()
            return true
        }
        if commandSelector == #selector(insertTab(_:)) || commandSelector == #selector(insertBacktab(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }
}
