/*
 * tako — In-memory theme draft: colors, ANSI 16, faces, size; saved or discarded
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Nothing touches disk until DesktopThemeLibrary.save; cancelling simply
/// drops the value. The preview is parsed from the exact text to be saved.
@MainActor
struct DesktopThemeDraft {
    static let colorKeys = ["background", "foreground", "cursor-color", "cursor-text",
                            "selection-background", "selection-foreground"]
    static let faceKeys = ["font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic"]

    let original: ThemePreset
    var name: String
    private(set) var text: String

    /// A user theme is edited in place unless `name` asks for a copy; a
    /// built-in one is always copied (the reference names it «X Copy»).
    init(original: ThemePreset, name: String? = nil) {
        self.original = original
        self.name = name ?? (original.isUser ? original.name : original.name + " Copy")
        self.text = original.config
    }

    var isDirty: Bool { text != original.config || name != original.name }
    var isCopy: Bool { !original.isUser || name != original.name }

    /// The same checks ThemePresetStore.save makes, shown before saving.
    var nameError: String? { Self.message { try ThemePresetStore.validatePresetName(name) } }
    var configError: String? { Self.message { try ThemePresetConfig.validate(text) } }
    var canSave: Bool { nameError == nil && configError == nil }

    private static func message(_ check: () throws -> Void) -> String? {
        do { try check(); return nil } catch { return error.localizedDescription }
    }

    func value(_ key: String) -> String? {
        lines.reversed().compactMap { KeybindConfigFile.parseConfigKeyValue($0) }.first { $0.key == key }?.value
    }

    mutating func set(_ key: String, _ value: String?) {
        var out = lines.filter { KeybindConfigFile.parseConfigKeyValue($0)?.key != key }
        if let value { out.append("\(key) = \(value)") }
        text = Self.join(out)
    }

    func paletteColor(_ index: Int) -> String? {
        paletteLines.last { $0.index == index }?.color
    }

    mutating func setPalette(_ index: Int, _ color: String?) {
        guard (0..<16).contains(index) else { return }
        var out = lines.filter { line in
            guard let parsed = KeybindConfigFile.parseConfigKeyValue(line), parsed.key == "palette" else { return true }
            return Self.paletteEntry(parsed.value)?.index != index
        }
        if let color { out.append("palette = \(index)=\(color)") }
        text = Self.join(out)
    }

    /// Fractional sizes are kept; out-of-range input is rejected, not clamped.
    @discardableResult
    mutating func setFontSize(_ size: Double) -> Bool {
        let rendered = size.rounded() == size ? String(Int(size)) : String(size)
        guard AppearanceValidator.isValidFontSize(rendered) else { return false }
        set("font-size", rendered)
        return true
    }

    /// Raw config editing for keys the structured editor does not expose.
    mutating func replaceText(_ newText: String) { text = newText }

    func preview(dark: Bool) -> TerminalTheme {
        TerminalTheme.parse(config: text, configPath: nil, darkAppearance: dark)
    }

    private var lines: [String] { text.components(separatedBy: "\n") }

    private var paletteLines: [(index: Int, color: String)] {
        lines.compactMap { KeybindConfigFile.parseConfigKeyValue($0) }.filter { $0.key == "palette" }
            .compactMap { Self.paletteEntry($0.value) }
    }

    private static func paletteEntry(_ value: String) -> (index: Int, color: String)? {
        guard let eq = value.firstIndex(of: "="), let index = Int(value[..<eq].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (index, value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }

    private static func join(_ lines: [String]) -> String {
        var trimmed = lines
        while trimmed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { trimmed.removeLast() }
        return trimmed.joined(separator: "\n") + "\n"
    }
}
