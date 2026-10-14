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
@testable import TakoKit

@Suite(.serialized)
@MainActor
struct TerminalSettingsColorTests {

    @Test func allNineColorSettingsParsePersistAndSurviveThemeApplication() throws {
        let colorIds: [(id: String, defaultHex: String, customHex: String)] = [
            ("background", "#14100e", "#102030"),
            ("foreground", "#ede6df", "#ddeeff"),
            ("cursor-color", "#f4581c", "#ff00aa"),
            ("selection-background", "#352b23", "#224466"),
            ("tab-status-color-working", "#f4581c", "#ff8800"),
            ("tab-status-color-waiting", "#ff7a3d", "#ffcc00"),
            ("tab-status-color-done", "#7bd88f", "#00dd66"),
            ("tab-status-color-error", "#d54e53", "#ee1133"),
            ("tab-status-color-idle", "#8a7f76", "#667788"),
        ]

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)

        for entry in colorIds {
            let item = try #require(TerminalSettingRegistry.setting(for: entry.id))
            #expect(item.type == .color(defaultValue: entry.defaultHex))
            #expect(configFile.effectiveSettingValue(for: item) == entry.defaultHex)
            #expect(configFile.setSettingValue(entry.customHex, for: item))
            #expect(configFile.getSettingValue(for: item) == entry.customHex)
            #expect(configFile.effectiveSettingValue(for: item) == entry.customHex)
        }

        let loadedConfig = Tako.Config(at: configPath)
        #expect(loadedConfig.errors.isEmpty)

        for entry in colorIds {
            let cgColor = try #require(loadedConfig.theme.settingsColor(for: entry.id))
            let nsColor = try #require(NSColor(cgColor: cgColor))
            #expect(Tako.Brand.hexString(for: nsColor) == entry.customHex)
        }

        // Verify applying a named color theme preserves tabStatusColors
        let themeFile = tempDir.appendingPathComponent("custom-theme")
        try "background = #010203\nforeground = #fefefe\n".write(to: themeFile, atomically: true, encoding: .utf8)
        let mergedTheme = loadedConfig.theme.applyingTheme(named: "custom-theme", searchPaths: [tempDir.path])
        #expect(mergedTheme.tabStatusColors.count == 5)
        for state in ["working", "waiting", "done", "error", "idle"] {
            #expect(mergedTheme.tabStatusColors[state] != nil)
        }
    }

    @Test func dialogInteractiveColorEditingValidationSaveCancelAndReset() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable],
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
        dialog.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = dialog
        dialog.layoutSubtreeIfNeeded()

        let workingIdx = try #require(
            dialog.filteredSettingItems.firstIndex(where: { $0.id == "tab-status-color-working" })
        )
        let workingItem = dialog.filteredSettingItems[workingIdx]
        dialog.selectedSettingIndex = workingIdx
        dialog.scrollTo(workingIdx)

        // 1. Pressing Enter opens the inline HEX editor field
        dialog.toggleOrCycleSelectedSetting()
        let editField = try #require(dialog.colorEditField)
        #expect(editField.accessibilityIdentifier() == "terminal-setting-color-tab-status-color-working")
        #expect(editField.stringValue == "#f4581c")

        // 2. Invalid HEX is rejected without modifying config or closing editor
        editField.stringValue = "not-a-hex"
        let textView = NSTextView()
        #expect(dialog.control(editField, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(dialog.colorEditField != nil)
        #expect(dialog.statusMessage?.contains("Invalid color") == true)
        #expect((dialog.accessibilityValue() as? String) == "setting_color_invalid: tab-status-color-working")
        #expect(configFile.getSettingValue(for: workingItem) == nil)

        // 3. Valid 6-digit HEX (with or without uppercase/leading '#') normalizes and saves
        editField.stringValue = "12AB34"
        #expect(dialog.control(editField, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(dialog.colorEditField == nil)
        #expect(configFile.getSettingValue(for: workingItem) == "#12ab34")
        #expect(configFile.effectiveSettingValue(for: workingItem) == "#12ab34")
        #expect((dialog.accessibilityValue() as? String) == "setting_custom_success: tab-status-color-working")

        // 4. Re-opening and cancelling with Escape preserves the saved value
        dialog.toggleOrCycleSelectedSetting()
        let secondField = try #require(dialog.colorEditField)
        secondField.stringValue = "#ffffff"
        #expect(dialog.control(secondField, textView: textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(dialog.colorEditField == nil)
        #expect(configFile.effectiveSettingValue(for: workingItem) == "#12ab34")

        // 5. Mouse click on the swatch/value column (col >= 44) opens the editor
        let visibleRow = workingIdx - dialog.scrollSettingOffset
        let swatchFlippedPt = dialog.cell(45, 5 + visibleRow)
        let swatchWinPt = NSPoint(x: swatchFlippedPt.x + 2, y: dialog.bounds.height - swatchFlippedPt.y - 4)
        let clickEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: swatchWinPt,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ))
        dialog.mouseDown(with: clickEvent)
        #expect(dialog.colorEditField != nil)
        dialog.cancelEditingColor()

        // 6. Render dialog into bitmap to verify swatch drawing executes cleanly
        if let rep = dialog.bitmapImageRepForCachingDisplay(in: dialog.bounds) {
            dialog.cacheDisplay(in: dialog.bounds, to: rep)
        }

        // 7. Reset ('D') removes custom color override and restores default
        dialog.resetSelectedSetting()
        #expect(configFile.getSettingValue(for: workingItem) == nil)
        #expect(configFile.effectiveSettingValue(for: workingItem) == "#f4581c")

        // 8. Changing search filter while color editor has unsaved valid HEX cancels color edit
        // and lets Return in search act on the newly selected setting without saving the abandoned color
        dialog.toggleOrCycleSelectedSetting()
        let abandonedField = try #require(dialog.colorEditField)
        abandonedField.stringValue = "#abcdef"
        #expect(dialog.colorEditField != nil)
        let searchField = try #require(dialog.searchField)
        searchField.stringValue = "sync"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        #expect(dialog.colorEditField == nil)
        #expect(abandonedField.superview == nil)
        #expect(configFile.getSettingValue(for: workingItem) == nil)
        #expect(configFile.effectiveSettingValue(for: workingItem) == "#f4581c")

        let syncItem = try #require(dialog.filteredSettingItems.first)
        #expect(syncItem.id == "workspace-sync-window-frame")
        #expect(dialog.control(searchField, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(configFile.getSettingValue(for: syncItem) == "true")
        #expect(configFile.getSettingValue(for: workingItem) == nil)
    }

    @Test func customTabStatusColorsChangeActualTabBarDotAndReportColors() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            Tako.overrideTabStatusTheme = nil
            try? FileManager.default.removeItem(at: tempDir)
        }

        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)
        let dialog = TerminalSettingsDialog(
            style: .from(nil),
            configFile: configFile,
            initialTab: .terminalSettings
        )

        let customColors: [(settingId: String, dot: String, status: Tako.PaneStatus, customHex: String, defaultHex: String)] = [
            ("tab-status-color-idle", "dim", .idle, "#667788", Tako.Brand.hex(for: "dim")),
            ("tab-status-color-working", "ember", .working, "#ff8800", Tako.Brand.hex(for: "ember")),
            ("tab-status-color-waiting", "claw", .waitingForInput, "#ffcc00", Tako.Brand.hex(for: "claw")),
            ("tab-status-color-done", "ok", .done, "#00dd66", Tako.Brand.hex(for: "ok")),
            ("tab-status-color-error", "error", .error, "#ee1133", Tako.Brand.hex(for: "error")),
        ]

        // Apply all 5 custom tab status colors through TerminalSettingsDialog's editor
        for entry in customColors {
            let idx = try #require(dialog.filteredSettingItems.firstIndex(where: { $0.id == entry.settingId }))
            dialog.selectedSettingIndex = idx
            dialog.toggleOrCycleSelectedSetting()
            let field = try #require(dialog.colorEditField)
            field.stringValue = entry.customHex
            dialog.saveEditedColor()
        }

        let parsedConfig = Tako.Config(at: configPath)
        #expect(parsedConfig.errors.isEmpty)
        Tako.overrideTabStatusTheme = parsedConfig.theme

        let window = makeWindow(title: "color-dot-test")
        defer { Tako.CustomTabGroup.leave(window) }

        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(surface)
        defer { surface.removeFromSuperview() }

        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 38))
        window.contentView?.addSubview(bar)
        defer { bar.removeFromSuperview() }

        surface.crab.isFocused = false

        for entry in customColors {
            surface.crab.setStatus(entry.status, text: "test-\(entry.dot)")

            let report = Tako.tabVisualStatus(for: window)
            #expect(report.dot == entry.dot)
            #expect(report.hex == entry.customHex)
            #expect(report.color == entry.customHex)

            // Draw the tab bar and verify both pillIndicatorColor and paintedPillDots match customHex
            bar.layoutTabs()
            if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                bar.cacheDisplay(in: bar.bounds, to: rep)
            }
            let tab = try #require(bar.tabs.first)
            let indicatorHex = Tako.Brand.hexString(for: bar.pillIndicatorColor(for: tab))
            #expect(indicatorHex == entry.customHex)
            #expect(bar.paintedPillDots[ObjectIdentifier(window)] == entry.customHex)

            let children = (bar.accessibilityChildren() as? [NSAccessibilityElement]) ?? []
            let tabElem = try #require(children.first(where: { $0.accessibilityIdentifier() == "tab-0" }))
            #expect(tabElem.accessibilityHelp() == "dot:\(entry.customHex)")
        }

        // Reset all 5 settings via dialog.resetSelectedSetting() and verify default colors return
        for entry in customColors {
            let idx = try #require(dialog.filteredSettingItems.firstIndex(where: { $0.id == entry.settingId }))
            dialog.selectedSettingIndex = idx
            dialog.resetSelectedSetting()
        }
        Tako.overrideTabStatusTheme = Tako.Config(at: configPath).theme

        for entry in customColors {
            surface.crab.setStatus(entry.status, text: "reset-\(entry.dot)")
            let report = Tako.tabVisualStatus(for: window)
            #expect(report.hex == entry.defaultHex)
            bar.layoutTabs()
            let tab = try #require(bar.tabs.first)
            #expect(Tako.Brand.hexString(for: bar.pillIndicatorColor(for: tab)) == entry.defaultHex)
        }
    }
}
