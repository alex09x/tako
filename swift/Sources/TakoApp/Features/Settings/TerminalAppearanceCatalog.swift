/*
 * tako — Terminal appearance settings
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// Lists real Tako theme files and installed monospaced font families.
enum TerminalAppearanceCatalog {
    static let themeCategory = "Theme presets"
    static let fontCategory = "Font families"
    static let defaultFont = "Tako default"

    static func themeNames(paths: [String] = TerminalTheme.themeSearchPaths) -> [String] {
        var names: [String: String] = [:]
        for path in paths where !path.isEmpty {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            for url in (try? FileManager.default.contentsOfDirectory(at: directory,
                             includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? [] {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      FileManager.default.isReadableFile(atPath: url.path) else { continue }
                let name = url.lastPathComponent
                guard name.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else { continue }
                if names[name.lowercased()] == nil { names[name.lowercased()] = name }
            }
        }
        return names.values.sorted { a, b in
            if a == "TakoCore" { return b != "TakoCore" }
            if b == "TakoCore" { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    @MainActor static func fontFamilies() -> [String] {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 13)?.familyName }
            .filter { $0.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil })
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func themeItems(_ names: [String]) -> [TerminalSettingItem] {
        names.map { name in
            TerminalSettingItem(id: "theme", title: name, category: themeCategory,
                                type: .options(options: [name], defaultValue: "TakoCore"),
                                description: "Apply this theme; custom color overrides stay in place")
        } + TerminalSettingRegistry.colorSettings
    }

    static func fontItems(_ names: [String]) -> [TerminalSettingItem] {
        ([defaultFont] + names.filter { $0 != defaultFont }).map { name in
            TerminalSettingItem(id: "font-family", title: name, category: fontCategory,
                                type: .options(options: [name], defaultValue: defaultFont),
                                description: "Use this monospaced font for the terminal")
        }
    }

    static let sizeItems: [TerminalSettingItem] = [
        .init(id: "font-size", title: "Font size (pt)", category: "Font Size",
              type: .number(defaultValue: 13, min: 6, max: 72, step: 1),
              description: "Terminal font size in points")
    ]
}
