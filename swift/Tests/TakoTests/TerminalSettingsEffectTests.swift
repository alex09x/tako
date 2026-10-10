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

/// Integration and CUXT tests verifying that all settings in `TerminalSettingRegistry`
/// produce measurable concrete effects in `Tako.Config`, `TerminalTheme`, and app runtime.
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

    // MARK: - End-to-End Dialog Configuration Persistence & Effect

    @Test func endToEndDialogSettingUpdatePropagatesToConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config").path
        let configFile = KeybindConfigFile(configPath: configPath)

        // Verify initial reload gives default
        var loaded = Tako.Config(at: configPath)
        #expect(loaded.workspaceSyncWindowFrame == false)
        #expect(loaded.tabStyle == .pill)

        // Update workspace sync via registry item
        guard let wsItem = TerminalSettingRegistry.setting(for: "workspace-sync-window-frame"),
              let tabItem = TerminalSettingRegistry.setting(for: "tab-style"),
              let fontItem = TerminalSettingRegistry.setting(for: "font-size") else {
            Issue.record("Missing required setting registry items")
            return
        }

        #expect(configFile.setSettingValue("true", for: wsItem))
        #expect(configFile.setSettingValue("classic", for: tabItem))
        #expect(configFile.setSettingValue("16", for: fontItem))

        // Reload configuration from disk and verify effects
        loaded = Tako.Config(at: configPath)
        #expect(loaded.workspaceSyncWindowFrame == true)
        #expect(loaded.tabStyle == .classic)
        #expect(loaded.theme.fontSize == 16.0)

        // Now reset workspace sync back to default
        #expect(configFile.removeSettingValue(for: wsItem))
        loaded = Tako.Config(at: configPath)
        #expect(loaded.workspaceSyncWindowFrame == false)
        #expect(loaded.tabStyle == .classic) // still custom
    }

    // MARK: - Registry Completeness Check

    @Test func allSettingsInRegistryAreKnownAndHaveDefaults() {
        let all = TerminalSettingRegistry.allSettings
        #expect(all.count == 15)

        for setting in all {
            #expect(!setting.id.isEmpty)
            #expect(!setting.title.isEmpty)
            #expect(!setting.category.isEmpty)
            #expect(!setting.type.defaultStringValue.isEmpty)
        }
    }
}
