/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@Suite @MainActor
struct SetupAppearanceTests {
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
        model.chooseTheme("Live Dark")
        #expect(model.previewTheme.fontSize == 17)
        #expect(try String(contentsOf: config, encoding: .utf8).contains("font-size = 17"))
        #expect(model.progress.completed == false)
    }
}
