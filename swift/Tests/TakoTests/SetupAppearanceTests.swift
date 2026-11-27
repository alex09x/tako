/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI
import TakoCoreUI
import Testing
@testable import Tako

@Suite @MainActor
struct SetupAppearanceTests {
    @Test func setupLabelsRemainReadableOnLightAndLowContrastThemes() {
        for config in ["background = #f6f4ee\ncursor-color = #e05666",
                       "background = #f4f3f7\ncursor-color = #e05666",
                       "background = #222222\ncursor-color = #222222"] {
            let theme = TerminalTheme.parse(config: config)
            let colors = SetupPalette(theme: theme)
            #expect(SetupPalette.contrast(NSColor(colors.message), NSColor(cgColor: theme.background)!) >= 4.5)
            #expect(SetupPalette.contrast(NSColor(colors.primaryText), NSColor(cgColor: theme.cursorColor)!) >= 4.5)
        }
    }

    @Test func expandedPresetsLoadAsCompleteThemesInTheSetupCatalog() throws {
        let names = ["Tako Ember", "Tako Paper", "Tako Dawn", "Tako Ink", "Tako Violet"]
        // SwiftPM's test executable is not the packaged app resource bundle.
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/themes").path
        let available = TerminalAppearanceCatalog.themeNames(paths: [resources])
        let store = ThemePresetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                     searchPaths: [resources])
        for name in names {
            #expect(available.contains(name))
            #expect(SetupAppearanceStep.choiceNames(available: available, current: "TakoCore").contains(name))
            let preset = try store.load(named: name)
            try ThemePresetConfig.validate(preset.config)
        }
    }

    @Test func choosingColorsPreservesConfiguredFontSizeAndWeightWithoutLeavingSetup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, color, size) in [("Live Dark", "#102030", 13), ("Live Light", "#f0e0d0", 18)] {
            try "# tako-preset-version: 1\nbackground = \(color)\nfont-family = Menlo\nfont-size = \(size)\n"
                .write(to: themes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let suite = "SetupAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = root.appendingPathComponent("config")
        try "theme = Live Dark\nfont-family = Monaco\nfont-size = 17\nfont-weight = 550\n".write(to: config, atomically: true, encoding: .utf8)
        let model = SetupModel(store: SetupProgressStore(defaults: defaults), configPath: config.path)
        let before = try #require(NSColor(cgColor: model.previewTheme.background)?.usingColorSpace(.sRGB))
        model.chooseTheme("Live Light")
        let after = try #require(NSColor(cgColor: model.previewTheme.background)?.usingColorSpace(.sRGB))
        #expect(model.selectedTheme == "Live Light")
        #expect(model.previewTheme.fontSize == 17)
        #expect(model.previewTheme.fontFamily == "Monaco")
        #expect(model.previewTheme.fontWeight == 550)
        #expect(abs(after.redComponent - 240.0 / 255) < 0.001)
        #expect(before != after)
        // A second settings window or editor can update the file while setup is open.
        var external = try String(contentsOf: config, encoding: .utf8)
        external = external.replacingOccurrences(of: "font-size = 17", with: "font-size = 23")
        try external.write(to: config, atomically: true, encoding: .utf8)
        model.chooseTheme("Live Dark")
        #expect(model.previewTheme.fontSize == 23)
        #expect(try String(contentsOf: config, encoding: .utf8).contains("font-size = 23"))
        #expect(model.progress.completed == false)
    }

    /// `bold-is-bright` picks palette entries, so it belongs to the colour
    /// preset: switching presets is not pinned by the previous one's value.
    @Test func choosingColorsTakesTheNewPresetsBoldIsBright() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, bright) in [("Live Bright", "true"), ("Live Plain", "false")] {
            try "# tako-preset-version: 1\nbackground = #102030\nbold-is-bright = \(bright)\n"
                .write(to: themes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let suite = "SetupAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = root.appendingPathComponent("config")
        try "theme = Live Bright\nfont-size = 17\n".write(to: config, atomically: true, encoding: .utf8)
        let model = SetupModel(store: SetupProgressStore(defaults: defaults), configPath: config.path)
        #expect(model.previewTheme.boldIsBright)

        model.chooseTheme("Live Plain")
        #expect(model.selectedTheme == "Live Plain")
        #expect(model.previewTheme.boldIsBright == false)
        #expect(!(try String(contentsOf: config, encoding: .utf8)).contains("bold-is-bright"))
        #expect(model.previewTheme.fontSize == 17, "typography is still kept")

        model.chooseTheme("Live Bright")
        #expect(model.previewTheme.boldIsBright)
    }
}
