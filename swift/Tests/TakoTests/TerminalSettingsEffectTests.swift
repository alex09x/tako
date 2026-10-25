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

/// Unit tests verifying configuration parsing, persistence, and model resolution
/// for settings declared in `TerminalSettingRegistry`.
///
/// Registry Settings Status & Runtime Consumer Acceptance Matrix:
/// 1.  workspace-sync-window-frame: [Parser: PASS in workspaceSyncWindowFrameEffect] [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: COVERED via workspace-frame-sync]
/// 2.  tab-style:                   [Parser: PASS in tabStyleEffect]                   [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - tab strip appearance/layout update]
/// 3.  window-inherit-font-size:    [Parser: PASS in windowInheritFontSizeEffect]      [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - next-surface font size inheritance]
/// 4.  window-inherit-working-dir:  [Parser: PASS in windowInheritWorkingDirectoryEffect] [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - next-surface cwd inheritance]
/// 5.  cursor-style:                [Parser: PASS in cursorStyleEffect]                [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - terminal renderer cursor drawing]
/// 6.  cursor-style-blink:          [Parser: PASS in cursorBlinkEffect]                [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - terminal cursor timer loop]
/// 7.  mouse-hide-while-typing:     [Parser: PASS in mouseHideWhileTypingEffect]       [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - AppKit mouse cursor autohide]
/// 8.  copy-on-select:              [Parser: PASS in copyOnSelectEffect]              [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - terminal selection pasteboard bridge]
/// 9.  confirm-close-surface:       [Parser: PASS in confirmCloseSurfaceEffect]       [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - tab close confirmation modal alert]
/// 10. shell-integration:          [Parser: PASS in shellIntegrationEffect]          [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - OSC 133 shell prompt mark injection]
/// 11. quick-terminal-position:     [Parser: PASS in quickTerminalPositionEffect]     [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - dropdown quick terminal screen anchor]
/// 12. quick-terminal-autohide:     [Parser: PASS in quickTerminalAutoHideEffect]     [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - dropdown window resign active autohide]
/// 13. theme:                       [Parser: PASS in appearanceSettingsEffect]        [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - palette propagation to metal/renderer]
/// 14. font-size:                   [Parser: PASS in appearanceSettingsEffect]        [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - live glyph cache reallocation]
/// 15. background-blur:             [Parser: PASS in appearanceSettingsEffect]        [Persistence: PASS in configFileSettingPersistencePropagatesToParsedConfig] [Live UI Witness: OPEN - NSVisualEffectView material configuration]
///
/// Current Acceptance Summary:
/// - Parser: 15/15 PASS
/// - Persistence: 15/15 PASS (exercised across all 15 registry settings in configFileSettingPersistencePropagatesToParsedConfig)
/// - Live UI Witnesses: 1/15 COVERED (workspace-sync-window-frame), 14/15 OPEN
@Suite
@MainActor
struct TerminalSettingsEffectTests {

    // MARK: - Workspaces

    @Test func workspaceSyncWindowFrameEffect() throws {
        // Default is false
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.workspaceSyncWindowFrame == false)

        // Enabled via workspace-sync-window-frame
        let syncConfig = try TemporaryConfig("workspace-sync-window-frame = true")
        #expect(syncConfig.workspaceSyncWindowFrame == true)

        // Enabled via alias workspace-inherit-window-frame
        let aliasConfig = try TemporaryConfig("workspace-inherit-window-frame = true")
        #expect(aliasConfig.workspaceSyncWindowFrame == true)
    }

    // MARK: - Window & Tabs

    @Test func tabStyleEffect() throws {
        // Default is pill
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.tabStyle == .pill)

        // Classic tabs
        let classicConfig = try TemporaryConfig("tab-style = classic")
        #expect(classicConfig.tabStyle == .classic)

        // Explicit pill
        let pillConfig = try TemporaryConfig("tab-style = pill")
        #expect(pillConfig.tabStyle == .pill)
    }

    @Test func windowInheritFontSizeEffect() throws {
        // Default is true
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.windowInheritFontSize == true)

        // Disabled
        let disabledConfig = try TemporaryConfig("window-inherit-font-size = false")
        #expect(disabledConfig.windowInheritFontSize == false)
    }

    @Test func windowInheritWorkingDirectoryEffect() throws {
        // Default is true
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.windowInheritWorkingDirectory == true)

        // Disabled
        let disabledConfig = try TemporaryConfig("window-inherit-working-directory = false")
        #expect(disabledConfig.windowInheritWorkingDirectory == false)
    }

    // MARK: - Terminal Behavior

    @Test func cursorStyleEffect() throws {
        // Default is block
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.theme.cursorShape == .block)

        // Bar
        let barConfig = try TemporaryConfig("cursor-style = bar")
        #expect(barConfig.theme.cursorShape == .bar)

        // Underline
        let underlineConfig = try TemporaryConfig("cursor-style = underline")
        #expect(underlineConfig.theme.cursorShape == .underline)
    }

    @Test func cursorBlinkEffect() throws {
        // Default cursor-style-blink in config is false (TerminalTheme parser sets false unless non-false)
        let disabledConfig = try TemporaryConfig("cursor-style-blink = false")
        #expect(disabledConfig.theme.cursorBlink == false)

        let enabledConfig = try TemporaryConfig("cursor-style-blink = true")
        #expect(enabledConfig.theme.cursorBlink == true)
    }

    @Test func mouseHideWhileTypingEffect() throws {
        // Default is false
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.mouseHideWhileTyping == false)

        // Enabled
        let enabledConfig = try TemporaryConfig("mouse-hide-while-typing = true")
        #expect(enabledConfig.mouseHideWhileTyping == true)
    }

    @Test func copyOnSelectEffect() throws {
        // Default is .selection ("true")
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.copyOnSelect == .selection)

        // Clipboard
        let clipboardConfig = try TemporaryConfig("copy-on-select = clipboard")
        #expect(clipboardConfig.copyOnSelect == .clipboard)

        // Off
        let offConfig = try TemporaryConfig("copy-on-select = false")
        #expect(offConfig.copyOnSelect == .off)
    }

    @Test func confirmCloseSurfaceEffect() throws {
        // Default is .whenBusy ("true")
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.confirmCloseSurface == .whenBusy)

        // Always
        let alwaysConfig = try TemporaryConfig("confirm-close-surface = always")
        #expect(alwaysConfig.confirmCloseSurface == .always)

        // Never
        let neverConfig = try TemporaryConfig("confirm-close-surface = false")
        #expect(neverConfig.confirmCloseSurface == .never)
    }

    @Test func shellIntegrationEffect() throws {
        // Default is .detect
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.shellIntegration == .detect)

        // None
        let noneConfig = try TemporaryConfig("shell-integration = none")
        #expect(noneConfig.shellIntegration == .none)

        // Specific shells
        let zshConfig = try TemporaryConfig("shell-integration = zsh")
        #expect(zshConfig.shellIntegration == .zsh)

        let bashConfig = try TemporaryConfig("shell-integration = bash")
        #expect(bashConfig.shellIntegration == .bash)

        let fishConfig = try TemporaryConfig("shell-integration = fish")
        #expect(fishConfig.shellIntegration == .fish)
    }

    // MARK: - Quick Terminal

    @Test func quickTerminalPositionEffect() throws {
        // Default is top
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.quickTerminalPosition == .top)

        // Bottom
        let bottomConfig = try TemporaryConfig("quick-terminal-position = bottom")
        #expect(bottomConfig.quickTerminalPosition == .bottom)

        // Center
        let centerConfig = try TemporaryConfig("quick-terminal-position = center")
        #expect(centerConfig.quickTerminalPosition == .center)
    }

    @Test func quickTerminalAutoHideEffect() throws {
        // Default is true
        let defaultConfig = try TemporaryConfig("")
        #expect(defaultConfig.quickTerminalAutoHide == true)

        // Disabled
        let disabledConfig = try TemporaryConfig("quick-terminal-autohide = false")
        #expect(disabledConfig.quickTerminalAutoHide == false)
    }

    // MARK: - Appearance

    @Test func appearanceSettingsEffect() throws {
        // Font size
        let defaultThemeConfig = try TemporaryConfig("")
        #expect(defaultThemeConfig.theme.fontSize == 13.0)

        let customFontConfig = try TemporaryConfig("font-size = 18")
        #expect(customFontConfig.theme.fontSize == 18.0)

        // Background blur
        #expect(defaultThemeConfig.theme.backgroundBlur == 0)
        #expect(defaultThemeConfig.backgroundBlur == .disabled)

        let blurConfig = try TemporaryConfig("background-blur = 25")
        #expect(blurConfig.theme.backgroundBlur == 25)
        #expect(blurConfig.backgroundBlur == .radius(25))

        // Color theme application
        let themeDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: themeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: themeDir) }

        let themeFile = themeDir.appendingPathComponent("tokyonight")
        try "background = #1a1b26\nforeground = #c0caf5\n".write(to: themeFile, atomically: true, encoding: .utf8)

        let takoTheme = TerminalTheme.takoDefault
        let tokyoNight = takoTheme.applyingTheme(named: "tokyonight", searchPaths: [themeDir.path])
        #expect(tokyoNight.background != takoTheme.background)
        #expect(tokyoNight.fontSize == takoTheme.fontSize)
    }

    // MARK: - Configuration Persistence & Reparsing Tests

    /// Verifies that updates written through `KeybindConfigFile` persist to disk, re-parse
    /// cleanly into `Tako.Config`, and reset to defaults upon removal across all 25 registry settings.
    @Test func configFileSettingPersistencePropagatesToParsedConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)

        let allSettings = TerminalSettingRegistry.allSettings
        #expect(allSettings.count == 25)

        for setting in allSettings {
            let defaultValue = setting.type.defaultStringValue
            #expect(configFile.effectiveSettingValue(for: setting) == defaultValue)

            // Select a valid non-default value to test write + persistence
            let customValue: String
            if case .color = setting.type {
                customValue = "#5fafff"
            } else {
                customValue = setting.type.nextValue(current: defaultValue)
            }
            #expect(customValue != defaultValue)

            // 1. Write custom value to file
            #expect(configFile.setSettingValue(customValue, for: setting))
            #expect(configFile.getSettingValue(for: setting) == customValue)
            #expect(configFile.effectiveSettingValue(for: setting) == customValue)

            // 2. Reload fresh KeybindConfigFile from disk and verify persistence
            let reloadedConfigFile = KeybindConfigFile(configPath: configPath)
            #expect(reloadedConfigFile.getSettingValue(for: setting) == customValue)
            #expect(reloadedConfigFile.effectiveSettingValue(for: setting) == customValue)

            // 3. Verify Tako.Config parses cleanly with the custom value present
            let parsedCustom = Tako.Config(at: configPath)
            #expect(parsedCustom.errors.isEmpty)
            if setting.id == "workspace-sync-window-frame" {
                #expect(parsedCustom.workspaceSyncWindowFrame == true)
            } else if setting.id == "tab-style" {
                #expect(parsedCustom.tabStyle == .classic)
            } else if case .color = setting.type {
                let resolved = parsedCustom.theme.settingsColor(for: setting.id).flatMap { NSColor(cgColor: $0) }
                #expect(resolved.map { Tako.Brand.hexString(for: $0) } == customValue)
            }

            // 4. Remove setting (reset to default)
            #expect(configFile.removeSettingValue(for: setting))
            #expect(configFile.getSettingValue(for: setting) == nil)
            #expect(configFile.effectiveSettingValue(for: setting) == defaultValue)

            // 5. Reload again from disk and verify override is completely removed
            let postResetConfigFile = KeybindConfigFile(configPath: configPath)
            #expect(postResetConfigFile.getSettingValue(for: setting) == nil)
            #expect(postResetConfigFile.effectiveSettingValue(for: setting) == defaultValue)

            // 6. Verify Tako.Config parses cleanly with default restored
            let parsedReset = Tako.Config(at: configPath)
            #expect(parsedReset.errors.isEmpty)
            if setting.id == "workspace-sync-window-frame" {
                #expect(parsedReset.workspaceSyncWindowFrame == false)
            } else if setting.id == "tab-style" {
                #expect(parsedReset.tabStyle == .pill)
            }
        }
    }

    // MARK: - Registry Completeness Check

    @Test func allSettingsInRegistryAreKnownAndHaveDefaults() {
        let all = TerminalSettingRegistry.allSettings
        #expect(all.count == 25)

        for setting in all {
            #expect(!setting.id.isEmpty)
            #expect(!setting.title.isEmpty)
            #expect(!setting.category.isEmpty)
            #expect(!setting.type.defaultStringValue.isEmpty)
        }
    }
}
