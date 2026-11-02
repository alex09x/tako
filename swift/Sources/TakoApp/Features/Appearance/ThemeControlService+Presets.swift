/*
 * tako — Theme preset CLI operations
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension ThemeControlService {
    func listPresets() throws -> [String: JSON] {
        let names = TerminalAppearanceCatalog.themeNames(paths: presets.searchPaths)
        let rows = try names.map { name -> JSON in
            let preset = try loadPreset(name)
            return .object(["name": .string(preset.name), "is_user": .bool(preset.isUser)])
        }
        return ["themes": .array(rows)]
    }

    func createPreset(_ args: [String: JSON]) throws -> [String: JSON] {
        let name = try name(args)
        let provided = try checkedConfiguration(args["config"])
        guard args["from_theme"] == nil || args["from_theme"]?.string != nil else { throw ControlError(.invalid, "from_theme must be a preset name") }
        guard provided == nil || args["from_theme"] == nil else { throw ControlError(.invalid, "choose config text or a source preset, not both") }
        let config: String
        if let provided {
            config = provided
        } else if let sourceName = args["from_theme"]?.string {
            let original = try loadPreset(sourceName)
            let base = try baseTheme().applyingTheme(named: original.name, searchPaths: presets.searchPaths)
            config = ThemePresetEditor(store: presets, original: original, base: base, copyName: name).config
        } else {
            config = ThemePresetConfig.configuration(from: try baseTheme())
        }
        _ = try checkedConfiguration(.string(config))
        let saved = try presets.save(name: name, config: config)
        reload()
        return ["action": .string("create"), "name": .string(saved.name), "is_user": .bool(saved.isUser)]
    }

    func updatePreset(_ args: [String: JSON]) throws -> [String: JSON] {
        let original = try loadPreset(try name(args))
        guard original.isUser else { throw ThemePresetError.readOnlyBuiltin("copy \(original.name) before editing") }
        let supplied = try checkedConfiguration(args["config"])
        guard supplied == nil || args["settings"] == nil else { throw ControlError(.invalid, "choose a complete config or settings, not both") }
        let config: String
        if let supplied {
            config = supplied
        } else {
            guard let settings = args["settings"]?.array, !settings.isEmpty else { throw ControlError(.invalid, "theme set needs settings or configuration text") }
            let base = try baseTheme().applyingTheme(named: original.name, searchPaths: presets.searchPaths)
            let editor = ThemePresetEditor(store: presets, original: original, base: base, copyName: original.name)
            config = try ThemePresetConfig.updating(editor.config, settings: settings)
        }
        _ = try checkedConfiguration(.string(config))
        let saved = try presets.save(name: original.name, config: config, replacing: original)
        reload()
        return ["action": .string("set"), "name": .string(saved.name), "is_user": .bool(saved.isUser)]
    }
}
