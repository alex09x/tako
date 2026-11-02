/*
 * tako — Legacy assignment and copied asset reference regressions
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@MainActor @Suite(.serialized) struct ThemeControlReviewTests {
    @Test func legacyApplyPreservesTypographyAndExplicitFieldsInEveryScope() throws {
        let scene = try ThemeControlTestScene()
        try "background = #334455\n".write(to: scene.builtins.appendingPathComponent("Legacy"), atomically: true, encoding: .utf8)
        try "font-family = Monaco\nfont-size = 21\ncell-width = 12\nwindow-padding-x = 4\n".write(to: scene.config, atomically: true, encoding: .utf8)
        let workspace = UUID(), pane = UUID()
        try scene.styles.setValue("18", for: "font-size", scope: .workspace(workspace))
        try scene.styles.setValue("23", for: "font-size", scope: .pane(pane))
        try scene.call("apply", ["name": .string("Legacy")], scope: .global)
        try scene.call("apply", ["name": .string("Legacy")], scope: .workspace(workspace, nil))
        try scene.call("apply", ["name": .string("Legacy")], scope: .pane(pane, workspaceID: workspace))
        let global = try scene.service.baseTheme()
        #expect(global.fontSize == 21 && global.fontFamily == "Monaco" && global.cellWidth == 12)
        #expect(scene.styles.value(for: "font-size", scope: .workspace(workspace)) == "18")
        #expect(scene.styles.value(for: "font-size", scope: .pane(pane)) == "23")
        #expect(try scene.service.current(.pane(pane, workspaceID: workspace))["effective_config"]?.string?.contains("font-size = 23") == true)
    }

    @Test func copyingAcrossDirectoriesKeepsResolvedShaderAssetsAndOrder() throws {
        let scene = try ThemeControlTestScene()
        let assets = scene.builtins.appendingPathComponent("shaders")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for name in ["first.glsl", "second.glsl"] {
            try "void mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }\n".write(to: assets.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let text = ThemePresetConfig.marker + "\n# retain this note\nbackground = #112233\nfont-size = 17\ncustom-shader = shaders/first.glsl\ncustom-shader = shaders/second.glsl\n"
        try text.write(to: scene.builtins.appendingPathComponent("Shared"), atomically: true, encoding: .utf8)
        let original = TerminalTheme.takoDefault.applyingTheme(named: "Shared", searchPaths: scene.service.presets.searchPaths)
        try scene.call("create", ["name": .string("Copied"), "from_theme": .string("Shared")])
        let copy = TerminalTheme.takoDefault.applyingTheme(named: "Copied", searchPaths: scene.service.presets.searchPaths)
        #expect(copy.customShaders == original.customShaders && copy.customShaders.count == 2)
        #expect(copy.fontSize == original.fontSize && copy.background == original.background)
        #expect(try scene.service.presets.load(named: "Copied").config.contains("# retain this note"))
    }
}
