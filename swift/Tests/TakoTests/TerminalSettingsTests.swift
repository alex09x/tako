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

    // MARK: - Registry & Setting Types

    @Test func registryContainsWorkspaceSyncWindowFrame() {
        let item = TerminalSettingRegistry.setting(for: "workspace-sync-window-frame")
        #expect(item != nil)
        #expect(item?.id == "workspace-sync-window-frame")
        #expect(item?.category == "Workspaces")
        #expect(item?.type == .boolean(defaultValue: false))
        #expect(item?.aliases.contains("workspace-inherit-window-frame") == true)

        // Lookup by alias works
        let aliasItem = TerminalSettingRegistry.setting(for: "workspace-inherit-window-frame")
        #expect(aliasItem?.id == "workspace-sync-window-frame")
    }

    @Test func settingTypeNextAndPreviousValue() {
        // Boolean
        let boolType = TerminalSettingType.boolean(defaultValue: false)
        #expect(boolType.defaultStringValue == "false")
        #expect(boolType.nextValue(current: "false") == "true")
        #expect(boolType.nextValue(current: "true") == "false")

        // Options
        let optType = TerminalSettingType.options(options: ["modern", "native", "classic"], defaultValue: "modern")
        #expect(optType.defaultStringValue == "modern")
        #expect(optType.nextValue(current: "modern") == "native")
        #expect(optType.nextValue(current: "native") == "classic")
        #expect(optType.nextValue(current: "classic") == "modern")
        #expect(optType.previousValue(current: "classic") == "native")
        #expect(optType.previousValue(current: "modern") == "classic")

        // Number
        let numType = TerminalSettingType.number(defaultValue: 13, min: 10, max: 15, step: 2)
        #expect(numType.defaultStringValue == "13")
        #expect(numType.nextValue(current: "13") == "15")
        #expect(numType.nextValue(current: "15") == "10") // wraps to min
        #expect(numType.previousValue(current: "10") == "15") // wraps to max
    }

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

        // Right arrow again stays on rightmost tab (clamp)
        dialog.keyDown(with: keyEvent(code: 124)) // Right
        #expect(dialog.activeTab == .terminalSettings)

        // 3. Left arrow switches back to Keybindings tab
        dialog.keyDown(with: keyEvent(code: 123)) // Left
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
}

