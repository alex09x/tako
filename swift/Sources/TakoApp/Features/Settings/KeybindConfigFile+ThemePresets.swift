/*
 * tako — Apply a complete theme without stale global overrides
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension KeybindConfigFile {
    var appearanceThemePaths: [String] {
        (configPath.map { [URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("themes").path] } ?? [])
            + TerminalTheme.themeSearchPaths
    }

    var hasFullThemePreset: Bool {
        guard let item = TerminalSettingRegistry.setting(for: "theme"), let name = getSettingValue(for: item) else { return false }
        return TerminalTheme.presetContainsTypography(named: name, searchPaths: appearanceThemePaths)
    }

    static func configurationSelectingPreset(_ name: String, from text: String) -> String {
        var lines = text.components(separatedBy: "\n").filter { line in
            guard let entry = parseConfigKeyValue(line) else { return true }
            return entry.key != "theme" && !ThemePresetConfig.isAppearanceKey(entry.key)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("theme = \(name)")
        return lines.joined(separator: "\n") + "\n"
    }

    func applyFullThemePreset(_ name: String) -> Bool {
        guard let path = configPath else { return false }
        do {
            try ensureConfigFileExists(at: path)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let updated = Self.configurationSelectingPreset(name, from: text)
            try saveLinesAndReload(updated.components(separatedBy: "\n"), to: path)
            return true
        } catch { return false }
    }
}
