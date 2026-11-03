/*
 * tako — Editable, self-contained theme presets
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

@MainActor final class ThemePresetEditor {
    let store: ThemePresetStore
    private(set) var original: ThemePreset?
    let initialConfig: String
    let initialTheme: TerminalTheme
    var name: String
    var config: String
    var preview: ThemePresetPreview?
    weak var parent: TerminalSettingsDialog?

    init(store: ThemePresetStore, original: ThemePreset?, base: TerminalTheme, copyName: String) {
        self.store = store
        self.original = original?.isUser == true ? original : nil
        self.name = original?.isUser == true ? original!.name : copyName
        self.initialTheme = base
        var text = original.map { ThemePresetConfig.isVersioned($0.config) ? $0.config : ThemePresetConfig.legacyDraft($0.config) }
            ?? ThemePresetConfig.configuration(from: base)
        let defaults = ThemePresetConfig.configuration(from: base)
        let essential = ["background", "foreground", "cursor-color", "selection-background", "font-family", "font-size"]
            + (0..<16).map { "palette:\($0)" }
        for key in essential where ThemePresetConfig.value(for: key, in: text) == nil {
            text = ThemePresetConfig.setting(ThemePresetConfig.value(for: key, in: defaults), for: key, in: text)
        }
        self.config = text
        self.initialConfig = text
    }

    func validatedTheme() throws -> TerminalTheme {
        try ThemePresetConfig.parsed(config, configPath: store.directory.appendingPathComponent("_preview_").path)
    }
    var effectiveTheme: TerminalTheme { (try? validatedTheme()) ?? initialTheme }

    func value(for key: String) -> String? { ThemePresetConfig.value(for: key, in: config) }
    func setValue(_ value: String, for key: String) {
        config = ThemePresetConfig.setting(value, for: key, in: config)
    }
    func reset(_ key: String) {
        config = ThemePresetConfig.setting(ThemePresetConfig.value(for: key, in: initialConfig), for: key, in: config)
    }
    func isChanged(_ key: String) -> Bool { value(for: key) != ThemePresetConfig.value(for: key, in: initialConfig) }

    func effectiveValue(for key: String) -> String {
        if let value = value(for: key) { return value }
        let theme = effectiveTheme
        switch key {
        case "font-weight": return String(theme.fontWeight ?? 400)
        case "font-weight-bold": return String(theme.fontWeightBold ?? 700)
        case "font-weight-italic": return String(theme.fontWeightItalic ?? theme.fontWeight ?? 400)
        case "font-weight-bold-italic": return String(theme.fontWeightBoldItalic ?? 700)
        default: break
        }
        if key == "selection-foreground" { return Self.hex(theme.selectionForeground ?? theme.foreground) }
        return TerminalSettingRegistry.setting(for: key)?.type.defaultStringValue ?? ""
    }

    func save() throws -> ThemePreset {
        let saved = try store.save(name: name, config: config, replacing: original)
        original = saved
        return saved
    }

    static func hex(_ color: CGColor) -> String {
        guard let color = NSColor(cgColor: color) else { return "#000000" }
        return Tako.Brand.hexString(for: color)
    }

    static var colorItems: [TerminalSettingItem] {
        let terminal = TerminalSettingRegistry.colorSettings
        let selection = TerminalSettingItem(id: "selection-foreground", title: "Selection text color", category: "Terminal colors",
            type: .color(defaultValue: "#ffffff"), description: "Selected text color; remove this key in Config for automatic")
        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
                     "Bright black", "Bright red", "Bright green", "Bright yellow", "Bright blue", "Bright magenta", "Bright cyan", "Bright white"]
        return terminal + [selection] + names.enumerated().map { index, name in
            TerminalSettingItem(id: "palette:\(index)", title: "ANSI \(index) · \(name)", category: "ANSI palette",
                type: .color(defaultValue: "#000000"), description: "Terminal palette color \(index)")
        }
    }
}
