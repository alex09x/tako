/*
 * tako — English desktop copy and compatibility with saved theme selections
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import TakoCoreUI
import Testing
@testable import Tako

@MainActor
struct EnglishDesktopCopyTests {
    private func containsCyrillic(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0400...0x052f).contains($0.value) }
    }

    @Test func settingsSectionsAndRegistryCopyAreEnglish() {
        for section in DesktopSettingsSection.allCases {
            #expect(!containsCyrillic(section.title), "Section: \(section.title)")
        }
        for (key, copy) in DesktopSettingCopy.catalog {
            for value in [copy.title, copy.detail, copy.when, copy.unit] + copy.options.map(\.label) {
                #expect(!containsCyrillic(value), "\(key): \(value)")
            }
        }
        #expect(DesktopThemeFacts.places(1) == "place")
        for count in [0, 2, 11, 21, 101] { #expect(DesktopThemeFacts.places(count) == "places") }
    }

    @Test func renamedBuiltinThemesLoadOldSelectionsWithoutChangingUserData() throws {
        let themes = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/themes")
        let old = "\u{41a}\u{43e}\u{43d}\u{442}\u{440}\u{430}\u{441}\u{442}"
        let store = ThemePresetStore(directory: themes.appendingPathComponent("unused-user-directory"), searchPaths: [themes.path])
        for name in [old, old + " \u{441}\u{432}\u{435}\u{442}\u{43b}\u{430}\u{44f}"] {
            let canonical = TerminalTheme.canonicalThemeName(name)
            #expect(!containsCyrillic(canonical))
            let saved = try store.load(named: name)
            let expectedPreset = try store.load(named: canonical)
            #expect(saved.config == expectedPreset.config)
            #expect(throws: ThemePresetError.self) {
                try store.save(name: name, config: expectedPreset.config)
            }
            #expect(TerminalTheme.presetContainsTypography(named: name, searchPaths: [themes.path]))
            let configPath = themes.deletingLastPathComponent().appendingPathComponent("config").path
            let legacy = TerminalTheme.parse(config: "theme = \(name)", configPath: configPath)
            let expected = TerminalTheme.parse(config: "theme = \(canonical)", configPath: configPath)
            #expect(legacy.background.components == expected.background.components)
            #expect(legacy.fontFamily == expected.fontFamily && legacy.fontSize == expected.fontSize)
        }
        let custom = "custom-\u{43b}\u{43e}\u{433}\u{438}"
        #expect(TerminalTheme.canonicalThemeName(custom) == custom)
    }
}
