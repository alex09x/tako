// tako — Terminal emulator
// Copyright (c) 2026 Alexander Panasenko
//
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct SettingsConditionalThemeTests {
    @Test(arguments: [false, true])
    func inheritedValuesAndPreviewsFollowSystemAppearance(dark: Bool) throws {
        let previous = TakoSystemAppearance.isDark
        TakoSystemAppearance.update(dark)
        defer { TakoSystemAppearance.update(previous) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, family, size, background, cursor) in [
            ("Owned Light", "Menlo", 16, "#f7f7f7", "bar"),
            ("Owned Dark", "Monaco", 24, "#14100e", "block"),
        ] {
            try """
            # tako-preset-version: 1
            font-family = \(family)
            font-size = \(size)
            background = \(background)
            cursor-style = \(cursor)
            """.write(to: themes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let path = root.appendingPathComponent("config")
        try "theme = light:Owned Light,dark:Owned Dark\n".write(to: path, atomically: true, encoding: .utf8)
        let file = KeybindConfigFile(configPath: path.path)
        let color = try #require(TerminalSettingRegistry.setting(for: "background"))
        let cursor = try #require(TerminalSettingRegistry.setting(for: "cursor-style"))
        #expect(file.effectiveSettingValue(for: color) == (dark ? "#14100e" : "#f7f7f7"))
        #expect(file.effectiveSettingValue(for: TerminalAppearanceCatalog.sizeItems[0]) == (dark ? "24" : "16"))
        #expect(file.effectiveSettingValue(for: cursor) == (dark ? "block" : "bar"))
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: file, initialTab: .terminalSettings)
        #expect(dialog.typographyPreviewFont(size: 13).familyName == (dark ? "Monaco" : "Menlo"))
    }
}
