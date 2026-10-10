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

        // Toggle it
        dialog.toggleOrCycleSelectedSetting()
        #expect(configFile.getSettingValue(for: dialog.filteredSettingItems[wsIndex]) == "true")

        // Reset it
        dialog.resetSelectedSetting()
        #expect(configFile.getSettingValue(for: dialog.filteredSettingItems[wsIndex]) == nil)
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
}
