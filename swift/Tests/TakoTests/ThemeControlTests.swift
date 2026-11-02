/*
 * tako — Complete theme control and scope regressions
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

@MainActor @Suite(.serialized) struct ThemeControlTests {
    @Test func discoveryAndCopyExposeTheCompleteEditableTheme() throws {
        let scene = try ThemeControlTestScene()
        let names = try scene.call("list")["themes"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
        #expect(names.contains("TakoCore") && names.contains("Readonly"))
        let keys = try scene.call("keys")["keys"]?.array?.compactMap(\.string) ?? []
        #expect(keys.contains("font-family-bold-italic") && keys.contains("window-padding-x") && keys.contains("palette:255"))
        #expect(!keys.contains("command") && !keys.contains("grapheme-width-method"))
        #expect(keys.filter { !$0.hasPrefix("palette:") }.allSatisfy(ThemePresetConfig.isAppearanceKey))
        #expect(!(try scene.call("fonts")["fonts"]?.array ?? []).isEmpty)
        try scene.call("create", ["name": .string("Copied"), "from_theme": .string("Readonly")])
        let copy = try scene.service.presets.load(named: "Copied")
        #expect(copy.isUser && copy.config.contains("background = #010203"))
        #expect(copy.config.contains("font-size = 15"))
    }

    @Test func batchEditsIncludeExtendedPaletteTypographyMetricsAndRepeatedKeys() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        func pair(_ key: String, _ value: String?) -> JSON { .object(["key": .string(key), "value": value.map(JSON.string) ?? .null]) }
        try scene.call("set", ["name": .string("Mine"), "settings": .array([
            pair("font-family", "Menlo"), pair("font-size", "21"), pair("palette:255", "#abcdef"),
            pair("selection-foreground", "#112233"), pair("adjust-cell-width", "2"),
            pair("font-feature", "+liga"), pair("font-feature", "-dlig"),
            pair("background-blur-radius", "8"), pair("cell_width", "12")
        ])])
        let config = try scene.service.presets.load(named: "Mine").config
        #expect(config.contains("font-family = Menlo") && config.contains("font-size = 21"))
        #expect(ThemePresetConfig.value(for: "palette:255", in: config) == "#abcdef")
        #expect(config.contains("font-feature = +liga") && config.contains("font-feature = -dlig"))
        #expect(ThemePresetConfig.value(for: "background-blur", in: config) == "8")
        #expect(ThemePresetConfig.value(for: "cell-width", in: config) == "12")
        try scene.call("set", ["name": .string("Mine"), "settings": .array([pair("font-feature", "+calt")])])
        let replaced = try scene.service.presets.load(named: "Mine").config
        #expect(!replaced.contains("font-feature = +liga") && !replaced.contains("font-feature = -dlig"))
        try scene.call("set", ["name": .string("Mine"), "settings": .array([pair("palette:255", nil), pair("font-feature", nil)])])
        let reset = try scene.service.presets.load(named: "Mine").config
        #expect(ThemePresetConfig.value(for: "palette:255", in: reset) == nil)
        #expect(!reset.contains("font-feature ="))
    }

    @Test func assignmentAndInheritCoverGlobalWorkspaceAndPane() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        let workspace = scene.workspaces.createWorkspace(name: "Styled", color: "blue")
        let pane = UUID()
        try scene.call("apply", ["name": .string("Mine")], scope: .global)
        try scene.call("apply", ["name": .string("Readonly")], scope: .workspace(workspace.id, workspace.name))
        try scene.call("apply", ["name": .string("Mine")], scope: .pane(pane, workspaceID: workspace.id))
        let global = try scene.call("current", scope: .global)
        let local = try scene.call("current", scope: .workspace(workspace.id, workspace.name))
        let session = try scene.call("current", scope: .pane(pane, workspaceID: workspace.id))
        #expect(global["theme"]?.string == "Mine" && local["theme"]?.string == "Readonly")
        #expect(session["effective_config"]?.string?.contains("font-size = 19") == true)
        #expect(local["effective_config"]?.string?.contains("font-size = 15") == true)
        try scene.call("reset", scope: .pane(pane, workspaceID: workspace.id))
        #expect(try scene.call("current", scope: .pane(pane, workspaceID: workspace.id))["effective_config"]?.string?.contains("font-size = 15") == true)
        try scene.call("reset", scope: .workspace(workspace.id, workspace.name))
        #expect(try scene.call("current", scope: .workspace(workspace.id, workspace.name))["theme"] == .null)
        try scene.call("reset", scope: .global)
        let text = try String(contentsOf: scene.config, encoding: .utf8)
        #expect(text.contains("theme = TakoCore") && text.contains("command = /bin/sh") && text.contains("grapheme-width-method = legacy"))
    }

    @Test func invalidBatchAndUnsafeNamesNeverModifyThePreset() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        let original = try scene.service.presets.load(named: "Mine")
        let calls = scene.counter.value
        #expect(throws: Error.self) {
            try scene.call("set", ["name": .string("Mine"), "settings": .array([
                .object(["key": .string("background"), "value": .string("#abcdef")]),
                .object(["key": .string("command"), "value": .string("/bin/sh")])
            ])])
        }
        #expect(throws: Error.self) { try scene.call("set", ["name": .string("Readonly"), "config": .string("font-size = 19\n")]) }
        for name in ["../escape", " leading", "tako", "\"quoted\""] {
            #expect(throws: Error.self) { try scene.call("create", ["name": .string(name)]) }
        }
        #expect(try scene.service.presets.load(named: "Mine").config == original.config)
        #expect(scene.counter.value == calls)
    }

    @Test func storedInactiveScopeCanBeInspectedAndResetButUnknownTargetsAreRefused() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        let id = UUID()
        try scene.styles.applyPreset("Mine", scope: .pane(id))
        let request = ControlRequest(cmd: "theme", args: ["action": .string("current"), "scope": .string("pane"), "target": .string(id.uuidString)], from: nil)
        let scope = try ControlCommands.themeScope(request, all: [], service: scene.service)
        #expect(try scene.service.current(scope)["theme"]?.string == "Mine")
        _ = try scene.service.reset(scope)
        #expect(throws: Error.self) { try ControlCommands.themeScope(request, all: [], service: scene.service) }
        let bad = ControlRequest(cmd: "theme", args: ["action": .string("apply"), "name": .string("Mine")], from: nil)
        #expect(throws: Error.self) { try ControlCommands.themeScope(bad, all: [], service: scene.service) }
    }

    @Test func anOpenCatalogReflectsCliChangesWithoutApplyingTheFilteredEntry() throws {
        let scene = try ThemeControlTestScene()
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: scene.service.configFile, initialTab: .themes)
        let original = try Data(contentsOf: scene.config)
        try scene.create("New CLI Theme")
        #expect(dialog.filteredSettingItems.contains { $0.title == "New CLI Theme" })
        #expect(try Data(contentsOf: scene.config) == original)
    }
}
