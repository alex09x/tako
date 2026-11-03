/*
 * tako — Numeric typography and complete CLI configuration contracts
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import CoreText
import Testing
@testable import Tako

@MainActor @Suite(.serialized) struct ThemeTypographyControlTests {
    private let weightKeys = ["font-weight", "font-weight-bold", "font-weight-italic", "font-weight-bold-italic"]

    @Test func numericWeightsSurviveCopyImportAndAllAssignmentScopes() throws {
        let scene = try ThemeControlTestScene()
        try scene.create()
        let weights = zip(weightKeys, [550, 600, 450, 650]).map { key, value in
            JSON.object(["key": .string(key), "value": .string(String(value))])
        }
        try scene.call("set", ["name": .string("Mine"), "settings": .array(weights)])
        let text = try scene.service.presets.load(named: "Mine").config
        let parsed = try ThemePresetConfig.parsed(text)
        #expect(parsed.fontWeight == 550 && parsed.fontWeightBold == 600)
        #expect(parsed.fontWeightItalic == 450 && parsed.fontWeightBoldItalic == 650)
        let encoded = ThemePresetConfig.configuration(from: parsed)
        for (key, value) in zip(weightKeys, [550, 600, 450, 650]) {
            #expect(ThemePresetConfig.value(for: key, in: encoded) == String(value))
        }
        try scene.call("create", ["name": .string("Copied"), "from_theme": .string("Mine")])
        try scene.call("create", ["name": .string("Imported"), "config": .string(encoded)])
        let workspace = UUID(), pane = UUID()
        for scope in [ThemeControlScope.global, .workspace(workspace, nil), .pane(pane, workspaceID: workspace)] {
            try scene.call("apply", ["name": .string("Imported")], scope: scope)
            let current = try scene.service.current(scope)["effective_config"]?.string ?? ""
            #expect(current.contains("font-weight = 550") && current.contains("font-weight-bold-italic = 650"))
        }
        #expect(try scene.service.presets.load(named: "Copied").config.contains("font-weight = 550"))
        #expect(try String(contentsOf: scene.config, encoding: .utf8).contains("grapheme-width-method = legacy"))
    }

    @Test func invalidWeightUpdatesNeverReplaceThePreviousPreset() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        let file = scene.service.presets.directory.appendingPathComponent("Mine")
        let original = try Data(contentsOf: file)
        for key in weightKeys {
            for invalid in ["99", "901", "550.5", "nan", "", "bold"] {
                #expect(throws: (any Error).self) {
                    try scene.call("set", ["name": .string("Mine"), "settings": .array([
                        .object(["key": .string("font-size"), "value": .string("23")]),
                        .object(["key": .string(key), "value": .string(invalid)])])])
                }
                #expect(try Data(contentsOf: file) == original)
            }
        }
    }

    @Test func everyDiscoverableAppearanceSettingAcceptsCliSetAndUnset() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        let samples = Self.visualSamples(shader: scene.root.appendingPathComponent("fixture.glsl").path)
        let keys = ThemePresetConfig.controlKeys
        #expect(Set(samples.keys) == Set(keys), "Every advertised visual key needs an actual writable contract")
        let settings = keys.map { JSON.object(["key": .string($0), "value": .string(samples[$0]!)]) }
        try scene.call("set", ["name": .string("Mine"), "settings": .array(settings)])
        let full = try scene.service.presets.load(named: "Mine").config
        let theme = try ThemePresetConfig.parsed(full)
        #expect(theme.palette.count == 256 && theme.fontWeight == 550)
        #expect(theme.fontFeatures.count == 1 && theme.fontFamilyBoldItalic == "Menlo")
        #expect(theme.adjustCellHeight != nil && theme.cursorThickness == 2)
        try scene.call("set", ["name": .string("Mine"), "settings": .array(keys.map {
            .object(["key": .string($0), "value": .null])
        })])
        let reset = try scene.service.presets.load(named: "Mine").config
        #expect(ThemePresetConfig.value(for: "font-weight", in: reset) == nil)
        #expect(ThemePresetConfig.value(for: "palette:255", in: reset) == nil)
        #expect(try ThemePresetConfig.parsed(reset).fontWeight == nil)
    }

    @Test func cliFontDiscoveryIncludesBundledVariableFamilyAndItsRealAxis() throws {
        let scene = try ThemeControlTestScene()
        let result = try scene.call("fonts")
        #expect(result["fonts"]?.array?.contains(.string("Fira Code")) == true)
        let entry = try #require(result["font_details"]?.array?.compactMap(\.object).first { $0["family"]?.string == "Fira Code" })
        #expect(entry["variable_weight"]?.bool == true)
        #expect((entry["minimum_weight"]?.number ?? 999) <= 550)
        #expect((entry["maximum_weight"]?.number ?? 0) >= 600)
    }

    @Test func fontWeightControlsEditTheThemeAndPreviewTheSameVariableInstance() throws {
        let scene = try ThemeControlTestScene()
        _ = TerminalAppearanceCatalog.fontFamilies()
        let original = ThemePreset(name: "Preview", config: "# tako-preset-version: 1\nfont-family = Fira Code\nfont-size = 18\n", isUser: true)
        let editor = ThemePresetEditor(store: scene.service.presets, original: original, base: .takoDefault, copyName: "Preview")
        let dialog = TerminalSettingsDialog(style: .from(.takoDefault), configFile: scene.service.configFile,
                                           initialTab: .fonts, editor: editor)
        let before = try Data(contentsOf: scene.config)
        dialog.filterItems("regular weight")
        #expect(dialog.filteredSettingItems.map(\.id) == ["font-weight"])
        for _ in 0..<3 { dialog.toggleOrCycleSelectedSetting() }
        #expect(editor.value(for: "font-weight") == "550")
        #expect((dialog.accessibilityValue() as? String)?.contains("font-weight = 550") == true)
        let preview = dialog.typographyPreviewFont()
        let axes = CTFontCopyVariation(unsafeBitCast(preview, to: CTFont.self)) as? [NSNumber: NSNumber]
        #expect(axes?[NSNumber(value: 0x77676874)]?.intValue == 550)
        #expect(try Data(contentsOf: scene.config) == before)
        dialog.resetSelectedSetting()
        #expect(editor.value(for: "font-weight") == nil)
        dialog.withdraw()
    }

    static func visualSamples(shader: String) -> [String: String] {
        var values: [String: String] = [
            "font-size": "18", "font-synthetic-style": "true", "font-feature": "+liga",
            "cursor-opacity": "0.8", "background-opacity": "0.9", "cursor-thickness": "2",
            "background-blur": "3", "background-blur-radius": "3", "cell-width": "11", "cell_width": "11",
            "cell-height": "24", "cell_height": "24", "window-padding-x": "8,12", "window-padding-y": "6,10",
            "window-padding-balance": "true", "selection-invert-fg-bg": "false", "cursor-style-blink": "false",
            "window-padding-color": "background", "window-colorspace": "srgb", "cursor-style": "bar",
            "custom-shader": shader, "custom-shader-animation": "false", "palette": "17=#123456"
        ]
        for key in ["background", "foreground", "cursor-color", "selection-background", "selection-foreground",
                    "tab-status-color-working", "tab-status-color-waiting", "tab-status-color-done", "tab-status-color-error", "tab-status-color-idle"] { values[key] = "#123456" }
        for key in ["font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic"] { values[key] = "Menlo" }
        for key in ["font-style", "font-style-bold", "font-style-italic", "font-style-bold-italic"] { values[key] = "Regular" }
        for key in ["font-weight", "font-weight-bold", "font-weight-italic", "font-weight-bold-italic"] { values[key] = "550" }
        for key in ["adjust-cell-width", "adjust-cell-height", "adjust-font-baseline", "adjust-underline-position", "adjust-underline-thickness"] { values[key] = "1" }
        for index in 0...255 { values["palette:\(index)"] = "#123456" }
        return values
    }
}
