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

        // Cmd+1 ... Cmd+5 switch sections without reaching the terminal.
        if flags == .command, let key = event.charactersIgnoringModifiers,
           let number = Int(key), let tab = SettingsTab(rawValue: number - 1) {
            switchTab(to: tab)
            return true
        }

        // Allow standard clipboard and text editing shortcuts while searching
        if let field = colorEditField ?? searchField, window?.firstResponder == field.currentEditor() {
            if flags == .command, let char = event.charactersIgnoringModifiers?.lowercased() {
                if ["a", "c", "v", "x", "z"].contains(char) {
                    return super.performKeyEquivalent(with: event)
                }
            }
        }

        // Modal containment: block all other key equivalents
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

        if isTabBarFocused {
            handleTabBarKeyDown(event)
        } else {
            handleListKeyDown(event)
        }
    }

    private func handleTabBarKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow
            navigateTab(direction: -1)
        case 124: // Right arrow
            navigateTab(direction: 1)
        case 125: // Down arrow: enter settings list
            isTabBarFocused = false
            needsDisplay = true
        case 126: // Up arrow: stay on tab bar
            break
        case 36, 76: // Return / Enter: enter settings list
            isTabBarFocused = false
            needsDisplay = true
        case 53: // Esc: close dialog
            withdraw()
        case 48: // Tab: focus search field
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
                isTabBarFocused = false
                needsDisplay = true
            case "1":
                switchTab(to: .keybindings)
            case "2":
                switchTab(to: .terminalSettings)
            case "3":
                switchTab(to: .themes)
            case "4":
                switchTab(to: .fonts)
            case "5":
                switchTab(to: .fontSize)
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

    private func handleListKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 126: // Up arrow: move selection or focus tab bar if at top
            let currentIndex = activeTab == .keybindings ? selectedIndex : selectedSettingIndex
            if currentIndex <= 0 {
                isTabBarFocused = true
                needsDisplay = true
            } else {
                moveSelection(-1)
            }
        case 125: moveSelection(1)             // Down
        case 123:                              // Left
            if activeTab != .keybindings {
                toggleOrCycleSelectedSetting(reverse: true)
            }
        case 124:                              // Right
            if activeTab != .keybindings {
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
                if activeTab != .keybindings {
                    toggleOrCycleSelectedSetting()
                }
            case "1":
                switchTab(to: .keybindings)
            case "2":
                switchTab(to: .terminalSettings)
            case "3":
                switchTab(to: .themes)
            case "4":
                switchTab(to: .fonts)
            case "5":
                switchTab(to: .fontSize)
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

    func navigateTab(direction: Int) {
        let tabs = SettingsTab.allCases
        guard let currentIndex = tabs.firstIndex(of: activeTab) else { return }
        let newIndex = min(max(currentIndex + direction, 0), tabs.count - 1)
        if newIndex != currentIndex {
            switchTab(to: tabs[newIndex])
        }
    }

    func moveSelection(_ delta: Int) {
        cancelEditingColor()
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
        updateAccessibilityState()
        needsDisplay = true
    }

    func scrollTo(_ target: Int) {
        cancelEditingColor()
        pendingConflict = nil
        if activeTab == .keybindings {
            guard !filteredItems.isEmpty else { return }
            selectedIndex = min(max(target, 0), filteredItems.count - 1)
            scrollOffset = min(selectedIndex, max(filteredItems.count - visibleRows, 0))
        } else {
            guard !filteredSettingItems.isEmpty else { return }
            selectedSettingIndex = min(max(target, 0), filteredSettingItems.count - 1)
            scrollSettingOffset = min(selectedSettingIndex, max(filteredSettingItems.count - visibleRows, 0))
        }
        updateAccessibilityState()
        needsDisplay = true
    }

    // MARK: - NSTextFieldDelegate (Search)

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === colorEditField {
            cancelEditingColor(restoreFocus: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === colorEditField { return }
        cancelEditingColor(restoreFocus: false)
        pendingConflict = nil
        guard let field = searchField else { return }
        filterItems(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === colorEditField {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                saveEditedColor(); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelEditingColor(); return true
            }
            return false
        }
        cancelEditingColor(restoreFocus: false)
        if commandSelector == #selector(moveDown(_:)) {
            window?.makeFirstResponder(self)
            isTabBarFocused = false
            needsDisplay = true
            return true
        }
        if commandSelector == #selector(moveUp(_:)) {
            window?.makeFirstResponder(self)
            isTabBarFocused = true
            needsDisplay = true
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
            let fieldString = searchField?.stringValue ?? ""
            if !textView.string.isEmpty || !fieldString.isEmpty {
                textView.string = ""
                searchField?.stringValue = ""
                filterItems("")
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
