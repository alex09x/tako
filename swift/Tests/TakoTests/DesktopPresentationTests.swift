/*
 * tako — Desktop appearance independence and persisted configuration tests
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct DesktopPresentationTests {
    @Test func applicationColorsRemainIndependentOfTerminalThemeAndTypography() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("config")
        try "app-appearance = light\nbackground = #000000\nfont-size = 27.5\n".write(to: path, atomically: true, encoding: .utf8)
        let config = Tako.Config(at: path.path)
        #expect(config.errors.isEmpty)
        let presentation = DesktopPresentation(observe: false, systemIsDark: true)
        presentation.configure(config)
        #expect(!presentation.isDark)
        #expect(config.theme.fontSize == 27.5)
        #expect(presentation.palette.background != NSColor.black)
        presentation.updateSystemAppearance(isDark: false)
        presentation.updateSystemAppearance(isDark: true)
        #expect(!presentation.isDark)
        presentation.apply(DesktopPreferences { _ in nil })
        #expect(presentation.isDark)
        presentation.updateSystemAppearance(isDark: false)
        #expect(!presentation.isDark)
        #expect(config.theme.fontSize == 27.5)
    }

    @Test func desktopSettingsPersistThroughTheExistingConfigWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("config")
        try "# Keep this comment\nfont-size = 13.5\n".write(to: path, atomically: true, encoding: .utf8)
        let file = KeybindConfigFile(configPath: path.path)
        file.reload()
        let setting = try #require(TerminalSettingRegistry.setting(for: "status-show"))
        #expect(file.setSettingValue("false", for: setting))
        let reloaded = Tako.Config(at: path.path)
        #expect(reloaded.errors.isEmpty)
        #expect(!reloaded.desktopPreferences.showsStatus)
        #expect(!reloaded.desktopPreferences.shouldAnimateStatus(reduceMotion: false, isVisible: true))
        #expect(reloaded.theme.fontSize == 13.5)
        #expect(try String(contentsOf: path, encoding: .utf8).contains("# Keep this comment"))
        #expect(file.removeSettingValue(for: setting))
        #expect(Tako.Config(at: path.path).desktopPreferences.showsStatus)
    }

    @Test func motionPolicyRequiresVisibleIndicatorsAndHonorsReducedMotion() {
        let normal = DesktopPreferences { _ in nil }
        #expect(normal.shouldAnimateStatus(reduceMotion: false, isVisible: true))
        #expect(!normal.shouldAnimateStatus(reduceMotion: true, isVisible: true))
        #expect(!normal.shouldAnimateStatus(reduceMotion: false, isVisible: false))
        let staticStatus = DesktopPreferences { $0 == "status-animate" ? "false" : nil }
        #expect(staticStatus.showsStatus)
        #expect(!staticStatus.shouldAnimateStatus(reduceMotion: false, isVisible: true))
    }
}
