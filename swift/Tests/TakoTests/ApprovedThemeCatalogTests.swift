/*
 * tako — Approved desktop palettes must be real loadable full presets
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

@MainActor @Suite(.serialized)
struct ApprovedThemeCatalogTests {
    static let names = ["Ember", "Midnight", "Gruvbox", "Mocha", "Paper", "Latte", "Tokyo Night", "Nord",
                        "Dracula", "Frappé", "Rosé Pine", "Kanagawa", "Everforest", "Solarized", "Ayu Mirage",
                        "Monokai", "GitHub Dark", "High Contrast", "Solarized Light", "Rosé Pine Dawn",
                        "Everforest Light", "Gruvbox Light", "GitHub Light", "High Contrast Light"]
    @Test func approvedPalettesLoadWithFractionalTypographyAndCompleteANSI() throws {
        let themes = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/themes")
        let store = ThemePresetStore(directory: themes.appendingPathComponent("unused-user-directory"), searchPaths: [themes.path])
        let light = Set(["Paper", "Latte", "Solarized Light", "Rosé Pine Dawn", "Everforest Light",
                         "Gruvbox Light", "GitHub Light", "High Contrast Light"])
        for name in Self.names {
            let preset = try store.load(named: name)
            #expect(!preset.isUser)
            try ThemePresetConfig.validate(preset.config)
            let rendered = TerminalTheme.takoDefault.applyingTheme(named: name, searchPaths: [themes.path])
            #expect(rendered.fontSize == 12.5 && rendered.fontFamily == "Menlo", "\(name)")
            #expect(rendered.palette.count == 16)
            #expect(rendered.palette[8] != rendered.background, "\(name): ANSI 90 text must stay visible")
            if light.contains(name) {
                #expect(rendered.palette[0] == rendered.foreground, "\(name): ANSI black is dark text")
                #expect(rendered.palette[15] == rendered.background)
            }
            #expect(rendered.foreground != rendered.background, "\(name) must render visible text")
        }
        let retained = try store.load(named: "Tako Night")
        #expect(retained.config.contains("font-size = 13"), "Existing presets remain unchanged")
    }
}
