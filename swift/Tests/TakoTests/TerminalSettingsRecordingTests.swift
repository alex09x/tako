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
import Foundation
import Testing
@testable import Tako

@Suite
@MainActor
struct TerminalSettingsRecordingTests {
    @Test func emptySearchReturnDoesNotRecordAndClearingRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = KeybindConfigFile(configPath: directory.appendingPathComponent("config").path)
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: config)
        let field = try #require(dialog.searchField)
        let editor = NSTextView()
        let query = "echo 'leaked_to_pty' > /tmp/containment_leak.txt"
        field.stringValue = query
        editor.string = query
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(dialog.filteredItems.isEmpty)

        #expect(dialog.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!dialog.isRecording)
        #expect(dialog.accessibilityValue() as? String == "Keybindings: 0 items, No matching actions")
        #expect(field.stringValue == query)
        let overrides = config.customOverrides
        let split = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d",
            isARepeat: false, keyCode: 2
        ))
        #expect(dialog.performKeyEquivalent(with: split))
        #expect(!dialog.isRecording)
        #expect(dialog.pendingConflict == nil)
        #expect(config.customOverrides == overrides)

        // Search Escape clears the nested query; a valid selection can then record.
        #expect(dialog.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(field.stringValue.isEmpty)
        #expect(!dialog.filteredItems.isEmpty)
        #expect(!dialog.isWithdrawing)
        dialog.startRecording()
        #expect(dialog.isRecording)
        #expect(dialog.accessibilityValue() as? String == "recording")
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        dialog.handleRecordingKey(escape)
        #expect(!dialog.isRecording)
        #expect(dialog.accessibilityValue() as? String == "cancelled")
        #expect(!dialog.isWithdrawing)
        #expect(config.customOverrides == overrides)
    }

    @Test(arguments: [-1, Int.max])
    func invalidSelectionDoesNotStartRecording(index: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = KeybindConfigFile(configPath: directory.appendingPathComponent("config").path)
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: config)
        dialog.selectedIndex = index
        dialog.startRecording()
        #expect(!dialog.isRecording)
        #expect(dialog.statusMessage == nil)
    }
}
