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
    func startRecording() {
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

    func handleRecordingKey(_ event: NSEvent) {
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

    func handleConflictConfirmation(_ event: NSEvent, conflict: ConflictInfo) {
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

    func applyKeybind(action: String, trigger: String, title: String, reassignedFrom: String? = nil) {
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

    func resolveKey(from event: NSEvent) -> String? {
        if let name = KeybindRegistry.keyName(for: event.keyCode) {
            return name
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
        let c = chars.first!
        return (c.isASCII && (c.isLetter || c.isNumber)) ? String(c) : nil
    }
}
