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
struct TerminalSettingsNumericAndResponderTests {

    // MARK: - Numeric Bound Overflow & Underflow Protection

    @Test func numericSettingExtremeValuesDoNotOverflowOrCrash() {
        let numType = TerminalSettingType.number(defaultValue: 13, min: 10, max: 20, step: 2)

        // 1. Extreme Int.max string must not overflow or trap on nextValue
        let nextFromMax = numType.nextValue(current: String(Int.max))
        #expect(nextFromMax == "10") // Clamped to max, wrapped safely to min

        // Previous from Int.max is bounded to valid range
        let prevFromMax = numType.previousValue(current: String(Int.max))
        #expect(Int(prevFromMax)! <= 20 && Int(prevFromMax)! >= 10)

        // 2. Extreme Int.min string must not underflow or trap on previousValue
        let prevFromMin = numType.previousValue(current: String(Int.min))
        #expect(prevFromMin == "20") // Clamped to min, wrapped safely to max

        // Next from Int.min is bounded to valid range
        let nextFromMin = numType.nextValue(current: String(Int.min))
        #expect(Int(nextFromMin)! <= 20 && Int(nextFromMin)! >= 10)

        // 3. Out-of-range persisted values
        let nextFromHigh = numType.nextValue(current: "999999")
        #expect(nextFromHigh == "10")

        let prevFromLow = numType.previousValue(current: "-999999")
        #expect(prevFromLow == "20")

        // 4. Non-numeric / malformed strings
        #expect(numType.nextValue(current: "not-a-number") == "10")
        #expect(numType.previousValue(current: "not-a-number") == "20")
        #expect(numType.nextValue(current: "") == "10")
        #expect(numType.previousValue(current: "14.5.6") == "20")

        // 5. Zero or negative step protection
        let zeroStepType = TerminalSettingType.number(defaultValue: 12, min: 10, max: 20, step: 0)
        #expect(zeroStepType.nextValue(current: "10") == "11") // Safe fallback step = 1
        #expect(zeroStepType.previousValue(current: "10") == "20")
    }

    // MARK: - Search Field Responder Handoff & Zero-Result Recovery

    @Test func searchEditorHandoffToDialogAndZeroResultRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let dialog = TerminalSettingsDialog(
            style: .from(nil),
            configFile: configFile,
            initialTab: .terminalSettings
        )
        dialog.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView?.addSubview(dialog)

        let searchField = try #require(dialog.searchField)
        window.makeFirstResponder(searchField)
        searchField.stringValue = "sync"

        // 1. Mouse click on Tab Bar Row 1 transfers first responder away from search editor
        // Tab 2 ([2] Terminal Settings) starts around column 22
        let tab2Pt = NSPoint(x: dialog.cell(24, 1).x, y: dialog.cell(24, 1).y + 2)
        let tabLocationInWindow = dialog.convert(tab2Pt, to: nil)
        let clickTabEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: tabLocationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!

        dialog.mouseDown(with: clickTabEvent)
        #expect(dialog.isTabBarFocused == true)
        #expect(dialog.activeTab == .terminalSettings)
        #expect(dialog.searchField?.stringValue == "sync")
        #expect(window.firstResponder === dialog)

        // 2. Mouse click on list row transfers first responder and selects row
        let rowPt = NSPoint(x: dialog.cell(10, 6).x, y: dialog.cell(10, 6).y + 2)
        let rowLocationInWindow = dialog.convert(rowPt, to: nil)
        let clickRowEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: rowLocationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        )!

        dialog.mouseDown(with: clickRowEvent)
        #expect(dialog.isTabBarFocused == false)
        #expect(window.firstResponder === dialog)
        #expect(dialog.searchField?.stringValue == "sync")

        // 3. Zero-result search query produces empty list, and clearing recovers all items
        searchField.stringValue = "nonexistent_query_xyz_12345"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        #expect(dialog.filteredSettingItems.isEmpty)
        #expect(dialog.statusMessage?.contains("No matching") == true || dialog.filteredSettingItems.count == 0)

        // Recovery: clear search query
        searchField.stringValue = ""
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        #expect(dialog.filteredSettingItems.count == TerminalSettingRegistry.allSettings.count)

        // 4. cancelOperation with active field editor textView clears query and recovers items
        let fieldEditor = NSTextView()
        fieldEditor.string = "temporary_search"
        searchField.stringValue = "temporary_search"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))

        let handled = dialog.control(searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(handled == true)
        #expect(fieldEditor.string == "")
        #expect(searchField.stringValue == "")
        #expect(dialog.filteredSettingItems.count == TerminalSettingRegistry.allSettings.count)
    }
}
