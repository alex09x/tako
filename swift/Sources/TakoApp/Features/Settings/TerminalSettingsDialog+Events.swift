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

    override func cancelOperation(_ sender: Any?) {
        if isRecording {
            isRecording = false
            statusMessage = "Recording cancelled."
            recordingHeldModifiers = []
            setAccessibilityValue("cancelled")
            needsDisplay = true
        } else {
            withdraw()
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

        // Tab switching shortcuts: Cmd+1 for Keybindings, Cmd+2 for Terminal Settings
        if flags == .command && event.charactersIgnoringModifiers == "1" {
            switchTab(to: .keybindings)
            return true
        }
        if flags == .command && event.charactersIgnoringModifiers == "2" {
            switchTab(to: .terminalSettings)
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

        if let conflict = pendingConflict {
            handleConflictConfirmation(event, conflict: conflict)
            return
        }

        switch event.keyCode {
        case 126: moveSelection(-1)            // Up
        case 125: moveSelection(1)             // Down
        case 123:                              // Left
            if activeTab == .terminalSettings {
                toggleOrCycleSelectedSetting(reverse: true)
            }
        case 124:                              // Right
            if activeTab == .terminalSettings {
                toggleOrCycleSelectedSetting(reverse: false)
            }
        case 116: moveSelection(-visibleRows) // Page Up
        case 121: moveSelection(visibleRows)  // Page Down
        case 115: scrollTo(0)                 // Home
        case 119:                             // End
            let count = activeTab == .keybindings ? filteredItems.count : filteredSettingItems.count
            scrollTo(max(count - 1, 0))
        case 36, 76:                          // Return / Enter
            if activeTab == .keybindings {
                startRecording()
            } else {
                toggleOrCycleSelectedSetting()
            }
        case 53: withdraw()                    // Esc
        case 48:                               // Tab -> Focus search
            if let field = searchField {
                window?.makeFirstResponder(field)
            }
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { break }
            if chars == "\u{1b}" {
                withdraw()
                return
            }
            switch chars {
            case " ":
                if activeTab == .terminalSettings {
                    toggleOrCycleSelectedSetting()
                }
            case "1":
                switchTab(to: .keybindings)
            case "2":
                switchTab(to: .terminalSettings)
            case "r":
                if activeTab == .keybindings {
                    startRecording()
                } else {
                    toggleOrCycleSelectedSetting()
                }
            case "d":
                if activeTab == .keybindings {
                    resetSelected()
                } else {
                    resetSelectedSetting()
                }
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
        if (event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}") && flags.isEmpty {
            isRecording = false
            statusMessage = "Recording cancelled."
            recordingHeldModifiers = []
            setAccessibilityValue("cancelled")
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

        if let conflict = configFile.findConflict(for: trigger, targetAction: item.id) {
            let formatted = KeybindRegistry.format(trigger: trigger)
            let shortConflict = String(conflict.title.prefix(18))
            pendingConflict = ConflictInfo(targetItem: item, conflictingItem: conflict, trigger: trigger)
            let msg = "Conflict: \(formatted) used by '\(shortConflict)'. Overwrite? (Return=Yes, Esc=No)"
            statusMessage = msg
            setAccessibilityValue("conflict: \(msg)")
            isRecording = false
            recordingHeldModifiers = []
            needsDisplay = true
            return
        }

        applyKeybind(action: item.id, trigger: trigger, title: item.title)
    }

    private func handleConflictConfirmation(_ event: NSEvent, conflict: ConflictInfo) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Return / Enter (36, 76) or 'y' confirms overwrite
        if event.keyCode == 36 || event.keyCode == 76 || chars == "y" {
            pendingConflict = nil
            let conflictCanonical = KeybindConfigFile.canonicalActionName(conflict.conflictingItem.id)
            if configFile.customOverrides[conflictCanonical] != nil {
                configFile.removeKeybind(action: conflict.conflictingItem.id)
            }
            applyKeybind(action: conflict.targetItem.id, trigger: conflict.trigger, title: conflict.targetItem.title, reassignedFrom: conflict.conflictingItem.title)
            return
        }

        // Esc (53) or 'n' cancels overwrite
        if event.keyCode == 53 || chars == "n" {
            pendingConflict = nil
            statusMessage = "Reassignment cancelled."
            setAccessibilityValue("cancelled: Reassignment cancelled.")
            needsDisplay = true
            return
        }

        // Any other key clears pending conflict and handles the key normally
        pendingConflict = nil
        keyDown(with: event)
    }

    private func applyKeybind(action: String, trigger: String, title: String, reassignedFrom: String? = nil) {
        if configFile.setKeybind(action: action, trigger: trigger) {
            let formatted = KeybindRegistry.format(trigger: trigger)
            if let from = reassignedFrom {
                statusMessage = "Reassigned \(formatted) from '\(from)' to '\(title)'."
            } else {
                statusMessage = "Updated '\(title)' to \(formatted)."
            }
        } else {
            statusMessage = "Error: Failed to write to config file."
        }
        setAccessibilityValue(statusMessage ?? "updated")
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
        pendingConflict = nil
        let pt = convert(event.locationInWindow, from: nil)
        guard cardRect.contains(pt) else {
            // Modal: clicks on backdrop do not dismiss and do not pass through to terminal
            return
        }

        // Check Row 1 clicks for tab switching: [1] Keybindings, [2] Terminal Settings
        let tabY = cell(0, 1).y
        if pt.y >= tabY && pt.y < tabY + cellHeight {
            let tab1Title = " [1] Keybindings "
            let tab1Col = 3
            let tab2Col = tab1Col + tab1Title.count + 2
            let tab2Title = " [2] Terminal Settings "
            let relCol = Int((pt.x - cell(0, 0).x) / cellWidth)
            if relCol >= tab1Col && relCol < tab1Col + tab1Title.count {
                switchTab(to: .keybindings)
                return
            } else if relCol >= tab2Col && relCol < tab2Col + tab2Title.count {
                switchTab(to: .terminalSettings)
                return
            }
        }

        let startY = cell(0, 5).y
        let rowHeight = cellHeight
        if pt.y >= startY && pt.y < startY + CGFloat(visibleRows) * rowHeight {
            let clickedVisible = Int((pt.y - startY) / rowHeight)
            if activeTab == .keybindings {
                let targetIdx = scrollOffset + clickedVisible
                if targetIdx < filteredItems.count {
                    selectedIndex = targetIdx
                    if event.clickCount == 2 {
                        startRecording()
                    } else {
                        needsDisplay = true
                    }
                }
            } else {
                let targetIdx = scrollSettingOffset + clickedVisible
                if targetIdx < filteredSettingItems.count {
                    selectedSettingIndex = targetIdx
                    if event.clickCount == 2 {
                        toggleOrCycleSelectedSetting()
                    } else {
                        needsDisplay = true
                    }
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
        pendingConflict = nil
        if activeTab == .keybindings {
            guard !filteredItems.isEmpty else { return }
            selectedIndex = min(max(selectedIndex + delta, 0), filteredItems.count - 1)
            if selectedIndex < scrollOffset {
                scrollOffset = selectedIndex
            } else if selectedIndex >= scrollOffset + visibleRows {
                scrollOffset = selectedIndex - visibleRows + 1
            }
        } else {
            guard !filteredSettingItems.isEmpty else { return }
            selectedSettingIndex = min(max(selectedSettingIndex + delta, 0), filteredSettingItems.count - 1)
            if selectedSettingIndex < scrollSettingOffset {
                scrollSettingOffset = selectedSettingIndex
            } else if selectedSettingIndex >= scrollSettingOffset + visibleRows {
                scrollSettingOffset = selectedSettingIndex - visibleRows + 1
            }
        }
        needsDisplay = true
    }

    func scrollTo(_ target: Int) {
        pendingConflict = nil
        if activeTab == .keybindings {
            guard !filteredItems.isEmpty else { return }
            selectedIndex = min(max(target, 0), filteredItems.count - 1)
            scrollOffset = max(0, min(selectedIndex, filteredItems.count - visibleRows))
        } else {
            guard !filteredSettingItems.isEmpty else { return }
            selectedSettingIndex = min(max(target, 0), filteredSettingItems.count - 1)
            scrollSettingOffset = max(0, min(selectedSettingIndex, filteredSettingItems.count - visibleRows))
        }
        needsDisplay = true
    }

    func startRecording() {
        guard selectedIndex < filteredItems.count else { return }
        pendingConflict = nil
        isRecording = true
        recordingHeldModifiers = []
        statusMessage = "Press shortcut to record. Esc cancels, Backspace clears."
        window?.makeFirstResponder(self)
        setAccessibilityValue("recording")
        needsDisplay = true
    }

    func resetSelected() {
        guard selectedIndex < filteredItems.count else { return }
        pendingConflict = nil
        let item = filteredItems[selectedIndex]
        let canonicalId = KeybindConfigFile.canonicalActionName(item.id)
        let wasCustom = configFile.customOverrides[canonicalId] != nil
        if configFile.removeKeybind(action: item.id) {
            if wasCustom {
                statusMessage = "Reset '\(item.title)' to default."
            } else {
                statusMessage = "'\(item.title)' is already at default."
            }
            setAccessibilityValue("reset_success: \(statusMessage ?? "")")
        } else {
            statusMessage = "Error: Failed to reset config file."
            setAccessibilityValue("reset_error: \(statusMessage ?? "")")
        }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if activeTab == .keybindings {
            if delta > 0 {
                scrollOffset = max(scrollOffset - 1, 0)
            } else if delta < 0 {
                scrollOffset = min(scrollOffset + 1, max(filteredItems.count - visibleRows, 0))
            }
        } else {
            if delta > 0 {
                scrollSettingOffset = max(scrollSettingOffset - 1, 0)
            } else if delta < 0 {
                scrollSettingOffset = min(scrollSettingOffset + 1, max(filteredSettingItems.count - visibleRows, 0))
            }
        }
        needsDisplay = true
    }

    // MARK: - NSTextFieldDelegate (Search)

    func controlTextDidChange(_ obj: Notification) {
        pendingConflict = nil
        guard let field = searchField else { return }
        filterItems(field.stringValue)
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
            if activeTab == .keybindings {
                startRecording()
            } else {
                toggleOrCycleSelectedSetting()
            }
            return true
        }
        if commandSelector == #selector(insertTab(_:)) || commandSelector == #selector(insertBacktab(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }
}
