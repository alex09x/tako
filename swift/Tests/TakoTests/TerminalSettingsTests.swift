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
struct TerminalSettingsTests {

    // MARK: - Config File Setting Persistence

    @Test func setAndGetSettingValueInConfigFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)

        guard let item = TerminalSettingRegistry.setting(for: "workspace-sync-window-frame") else {
            Issue.record("Missing workspace-sync-window-frame")
            return
        }

        #expect(configFile.getSettingValue(for: item) == nil)
        #expect(configFile.effectiveSettingValue(for: item) == "false")

        // Set to true
        #expect(configFile.setSettingValue("true", for: item))
        #expect(configFile.getSettingValue(for: item) == "true")
        #expect(configFile.effectiveSettingValue(for: item) == "true")

        // Remove / reset back to default
        #expect(configFile.removeSettingValue(for: item))
        #expect(configFile.getSettingValue(for: item) == nil)
        #expect(configFile.effectiveSettingValue(for: item) == "false")
    }

    // MARK: - TerminalSettingsDialog Interaction

    @Test func dialogTabSwitchingAndSettingToggle() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)

        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: configFile, initialTab: .keybindings)
        #expect(dialog.activeTab == .keybindings)

        // Switch to Terminal Settings
        dialog.switchTab(to: .terminalSettings)
        #expect(dialog.activeTab == .terminalSettings)
        #expect(!dialog.filteredSettingItems.isEmpty)

        // Find workspace sync setting index
        guard let wsIndex = dialog.filteredSettingItems.firstIndex(where: { $0.id == "workspace-sync-window-frame" }) else {
            Issue.record("workspace-sync-window-frame not in dialog items")
            return
        }
        dialog.selectedSettingIndex = wsIndex

        // Toggle it to true (custom)
        dialog.toggleOrCycleSelectedSetting()
        #expect(configFile.getSettingValue(for: dialog.filteredSettingItems[wsIndex]) == "true")
        #expect(configFile.effectiveSettingValue(for: dialog.filteredSettingItems[wsIndex]) == "true")

        // Toggle it again to false (back to default without pressing reset)
        dialog.toggleOrCycleSelectedSetting()
        #expect(configFile.getSettingValue(for: dialog.filteredSettingItems[wsIndex]) == nil)
        #expect(configFile.effectiveSettingValue(for: dialog.filteredSettingItems[wsIndex]) == "false")

        // Toggle to true again, then use reset button
        dialog.toggleOrCycleSelectedSetting()
        #expect(configFile.getSettingValue(for: dialog.filteredSettingItems[wsIndex]) == "true")
        dialog.resetSelectedSetting()
        #expect(configFile.getSettingValue(for: dialog.filteredSettingItems[wsIndex]) == nil)
        #expect(configFile.effectiveSettingValue(for: dialog.filteredSettingItems[wsIndex]) == "false")
    }

    @Test func dialogSearchFiltersSettings() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)

        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: configFile, initialTab: .terminalSettings)
        #expect(dialog.activeTab == .terminalSettings)

        dialog.filterItems("workspace")
        #expect(!dialog.filteredSettingItems.isEmpty)
        #expect(dialog.filteredSettingItems.allSatisfy {
            $0.id.localizedCaseInsensitiveContains("workspace") ||
            $0.title.localizedCaseInsensitiveContains("workspace") ||
            $0.category.localizedCaseInsensitiveContains("workspace")
        })

        dialog.filterItems("")
        #expect(dialog.filteredSettingItems.count == dialog.allSettingItems.count)
    }

    // MARK: - Keyboard Navigation (Tab Bar <-> List)

    @Test func dialogKeyboardNavigationBetweenTabsAndList() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)

        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: configFile, initialTab: .keybindings)
        #expect(dialog.activeTab == .keybindings)
        #expect(dialog.isTabBarFocused == false)

        func keyEvent(code: UInt16, chars: String = "") -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: code
            )!
        }

        // 1. Up arrow from row 0 navigates up into the Tab bar
        dialog.selectedIndex = 0
        dialog.keyDown(with: keyEvent(code: 126)) // Up
        #expect(dialog.isTabBarFocused == true)
        #expect(dialog.activeTab == .keybindings)

        // 2. Right arrow switches to Terminal Settings tab
        dialog.keyDown(with: keyEvent(code: 124)) // Right
        #expect(dialog.activeTab == .terminalSettings)
        #expect(dialog.isTabBarFocused == true)

        // The new appearance sections follow the original two tabs.
        dialog.keyDown(with: keyEvent(code: 124)) // Right
        #expect(dialog.activeTab == .themes)
        dialog.keyDown(with: keyEvent(code: 124))
        #expect(dialog.activeTab == .fonts)
        dialog.keyDown(with: keyEvent(code: 124))
        #expect(dialog.activeTab == .fontSize)
        dialog.keyDown(with: keyEvent(code: 124))
        #expect(dialog.activeTab == .fontSize)

        // 3. Left arrow returns to Keybindings.
        for _ in 0..<4 { dialog.keyDown(with: keyEvent(code: 123)) }
        #expect(dialog.activeTab == .keybindings)
        #expect(dialog.isTabBarFocused == true)

        // Left arrow again stays on leftmost tab (clamp)
        dialog.keyDown(with: keyEvent(code: 123)) // Left
        #expect(dialog.activeTab == .keybindings)

        // 4. Down arrow drops focus back down into the item list
        dialog.keyDown(with: keyEvent(code: 125)) // Down
        #expect(dialog.isTabBarFocused == false)

        // 5. Navigate Up into Tab bar, switch to Terminal Settings, then drop Down into list
        dialog.keyDown(with: keyEvent(code: 126)) // Up
        #expect(dialog.isTabBarFocused == true)
        dialog.keyDown(with: keyEvent(code: 124)) // Right
        #expect(dialog.activeTab == .terminalSettings)
        dialog.keyDown(with: keyEvent(code: 125)) // Down
        #expect(dialog.isTabBarFocused == false)
        #expect(dialog.activeTab == .terminalSettings)

        // 6. When in Terminal Settings list, Left/Right arrow modifies setting values, not tabs
        #expect(!dialog.filteredSettingItems.isEmpty)
        let firstSetting = dialog.filteredSettingItems[0]
        let initialVal = configFile.effectiveSettingValue(for: firstSetting)
        dialog.keyDown(with: keyEvent(code: 124)) // Right (cycle setting)
        let newVal = configFile.effectiveSettingValue(for: firstSetting)
        #expect(newVal != initialVal)
        #expect(dialog.activeTab == .terminalSettings)

        // Cycle back to default with Left arrow
        dialog.keyDown(with: keyEvent(code: 123)) // Left (reverse cycle)
        #expect(configFile.effectiveSettingValue(for: firstSetting) == initialVal)
        #expect(configFile.getSettingValue(for: firstSetting) == nil)

        // 7. Navigation within list: Up arrow moves selection up if > 0, doesn't focus tab bar until at 0
        dialog.selectedSettingIndex = 2
        dialog.keyDown(with: keyEvent(code: 126)) // Up
        #expect(dialog.selectedSettingIndex == 1)
        #expect(dialog.isTabBarFocused == false)

        dialog.keyDown(with: keyEvent(code: 126)) // Up
        #expect(dialog.selectedSettingIndex == 0)
        #expect(dialog.isTabBarFocused == false)

        dialog.keyDown(with: keyEvent(code: 126)) // Up (from 0)
        #expect(dialog.isTabBarFocused == true)

        // 8. Return / Enter key while on Tab bar enters the settings list
        dialog.keyDown(with: keyEvent(code: 36)) // Return
        #expect(dialog.isTabBarFocused == false)
    }

    // MARK: - Persistence Failure & Canonical Alias Precedence

    @Test func dialogPersistenceFailureReportsErrorAndRetainsState() throws {
        // 1. Invalid path: write failure when attempting to customize
        let invalidPath = "/dev/null/impossible_dir_\(UUID().uuidString)/config"
        let invalidConfigFile = KeybindConfigFile(configPath: invalidPath)

        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: invalidConfigFile, initialTab: .terminalSettings)
        #expect(dialog.activeTab == .terminalSettings)
        #expect(!dialog.filteredSettingItems.isEmpty)

        dialog.selectedSettingIndex = 0
        let item = dialog.filteredSettingItems[0]

        dialog.toggleOrCycleSelectedSetting()
        #expect(dialog.statusMessage?.hasPrefix("Error:") == true)
        #expect((dialog.accessibilityValue() as? String)?.contains("setting_write_error") == true)
        #expect(invalidConfigFile.getSettingValue(for: item) == nil)

        // 2. Read-only destination: reset failure when attempting to revert custom setting
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let configPath = tempDir.appendingPathComponent("config").path
        try "workspace-sync-window-frame = true\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: configPath)

        let readOnlyConfigFile = KeybindConfigFile(configPath: configPath)
        guard let wsIndex = dialog.filteredSettingItems.firstIndex(where: { $0.id == "workspace-sync-window-frame" }) else {
            Issue.record("Missing workspace-sync-window-frame setting")
            return
        }
        let readOnlyDialog = TerminalSettingsDialog(style: .from(nil), configFile: readOnlyConfigFile, initialTab: .terminalSettings)
        readOnlyDialog.selectedSettingIndex = wsIndex
        let wsItem = readOnlyDialog.filteredSettingItems[wsIndex]
        #expect(readOnlyConfigFile.getSettingValue(for: wsItem) == "true")

        readOnlyDialog.resetSelectedSetting()
        #expect(readOnlyDialog.statusMessage?.hasPrefix("Error:") == true)
        #expect((readOnlyDialog.accessibilityValue() as? String)?.contains("setting_reset_error") == true)
        #expect(readOnlyConfigFile.getSettingValue(for: wsItem) == "true")
    }

    @Test func canonicalKeyPrecedenceOverAliasMatchesRuntime() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        guard let wsItem = TerminalSettingRegistry.setting(for: "workspace-sync-window-frame") else {
            Issue.record("Missing workspace-sync-window-frame setting")
            return
        }

        let configPath = tempDir.appendingPathComponent("config").path

        // Case 1: canonical=true followed by alias=false -> canonical wins (true)
        let content1 = "workspace-sync-window-frame = true\nworkspace-inherit-window-frame = false\n"
        try content1.write(toFile: configPath, atomically: true, encoding: .utf8)
        var file = KeybindConfigFile(configPath: configPath)
        #expect(file.getSettingValue(for: wsItem) == "true")
        var runtimeConfig = Tako.Config(at: configPath)
        #expect(runtimeConfig.workspaceSyncWindowFrame == true)

        // Case 2: alias=false followed by canonical=true -> canonical wins (true)
        let content2 = "workspace-inherit-window-frame = false\nworkspace-sync-window-frame = true\n"
        try content2.write(toFile: configPath, atomically: true, encoding: .utf8)
        file = KeybindConfigFile(configPath: configPath)
        #expect(file.getSettingValue(for: wsItem) == "true")
        runtimeConfig = Tako.Config(at: configPath)
        #expect(runtimeConfig.workspaceSyncWindowFrame == true)

        // Case 3: canonical=false followed by alias=true -> canonical wins (false)
        let content3 = "workspace-sync-window-frame = false\nworkspace-inherit-window-frame = true\n"
        try content3.write(toFile: configPath, atomically: true, encoding: .utf8)
        file = KeybindConfigFile(configPath: configPath)
        #expect(file.getSettingValue(for: wsItem) == "false")
        runtimeConfig = Tako.Config(at: configPath)
        #expect(runtimeConfig.workspaceSyncWindowFrame == false)

        // Case 4: only alias present -> alias is resolved
        let content4 = "workspace-inherit-window-frame = true\n"
        try content4.write(toFile: configPath, atomically: true, encoding: .utf8)
        file = KeybindConfigFile(configPath: configPath)
        #expect(file.getSettingValue(for: wsItem) == "true")
        runtimeConfig = Tako.Config(at: configPath)
        #expect(runtimeConfig.workspaceSyncWindowFrame == true)
    }

    @Test func mouseSingleClickTogglesBooleanSetting() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config").path
        try "# Empty config\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        let configFile = KeybindConfigFile(configPath: configPath)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: configFile, initialTab: .terminalSettings)
        dialog.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = dialog

        guard let wsIndex = dialog.filteredSettingItems.firstIndex(where: { $0.id == "workspace-sync-window-frame" }) else {
            Issue.record("Missing workspace-sync-window-frame setting")
            return
        }
        let wsItem = dialog.filteredSettingItems[wsIndex]
        #expect(configFile.effectiveSettingValue(for: wsItem) == "false")

        // Target row in visible range
        dialog.scrollSettingOffset = max(0, wsIndex - 2)
        let visibleIdx = wsIndex - dialog.scrollSettingOffset
        let rowFlippedY = dialog.cell(0, 5).y + CGFloat(visibleIdx) * dialog.cellHeight + dialog.cellHeight / 2
        let rowWindowY = dialog.bounds.height - rowFlippedY
        let titleX = dialog.cell(10, 5).x
        let valueX = dialog.cell(46, 5).x

        // 1. Single click on title selects the row without toggling
        let titleClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: titleX, y: rowWindowY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        dialog.mouseDown(with: titleClick)
        #expect(dialog.selectedSettingIndex == wsIndex)
        #expect(configFile.effectiveSettingValue(for: wsItem) == "false")

        // 2. Single click on value column toggles the setting to true immediately
        let valueClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: valueX, y: rowWindowY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        )!
        dialog.mouseDown(with: valueClick)
        #expect(configFile.effectiveSettingValue(for: wsItem) == "true")
        #expect(configFile.getSettingValue(for: wsItem) == "true")
        #expect(dialog.selectedSettingIndex == wsIndex)

        // 3. Second single click toggles back to default false
        dialog.mouseDown(with: valueClick)
        #expect(configFile.effectiveSettingValue(for: wsItem) == "false")
        #expect(configFile.getSettingValue(for: wsItem) == nil)
    }
}

