/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension ThemePresetConfig {
    /// Validate theme preset configuration text.
    public static func validate(_ text: String) throws {
        var seenKeys = Set<String>()
        var seenPaletteIndexes = Set<Int>()

        let rawLines = text.components(separatedBy: "\n")
        for (zeroBasedLine, rawLine) in rawLines.enumerated() {
            let lineNum = zeroBasedLine + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("# tako-preset-version:") {
                    let version = trimmed.dropFirst("# tako-preset-version:".count).trimmingCharacters(in: .whitespaces)
                    guard version == "1" else {
                        throw ThemePresetError.unsupportedVersion(version)
                    }
                }
                continue
            }

            guard let eq = trimmed.firstIndex(of: "=") else {
                throw ThemePresetError.malformedLine(line: lineNum, "Missing '=' in configuration line '\(rawLine)'")
            }

            let key = String(trimmed[..<eq].trimmingCharacters(in: .whitespaces))
            let value = String(trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces))

            guard !key.isEmpty else {
                throw ThemePresetError.malformedLine(line: lineNum, "Empty configuration key in line '\(rawLine)'")
            }

            if key == "theme" {
                throw ThemePresetError.nestedThemeNotAllowed(line: lineNum, "Nested theme reference 'theme = \(value)' is not permitted")
            }

            if key == "palette" {
                let parts = value.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else {
                    throw ThemePresetError.malformedLine(line: lineNum, "Palette setting must be 'index=color', got '\(value)'")
                }
                let indexStr = parts[0].trimmingCharacters(in: .whitespaces)
                let colorStr = parts[1].trimmingCharacters(in: .whitespaces)

                guard let index = Int(indexStr), (0...15).contains(index) else {
                    throw ThemePresetError.invalidPaletteIndex(line: lineNum, "Palette index must be an integer between 0 and 15, got '\(indexStr)'")
                }
                guard isValidRGBColor(colorStr) else {
                    throw ThemePresetError.invalidColor(line: lineNum, key: "palette:\(index)", colorStr)
                }
                guard !seenPaletteIndexes.contains(index) else {
                    throw ThemePresetError.duplicateKey(line: lineNum, "Duplicate palette index \(index)")
                }
                seenPaletteIndexes.insert(index)
                continue
            }

            if key != "font-feature" {
                guard !seenKeys.contains(key) else {
                    throw ThemePresetError.duplicateKey(line: lineNum, "Duplicate appearance key '\(key)'")
                }
                seenKeys.insert(key)
            }

            try validateAppearanceKey(key, value: value, lineNum: lineNum)
        }
    }

    private static func validateAppearanceKey(_ key: String, value: String, lineNum: Int) throws {
        switch key {
        case "background", "foreground", "cursor-color", "selection-background", "selection-foreground":
            guard isValidRGBColor(value) else {
                throw ThemePresetError.invalidColor(line: lineNum, key: key, value)
            }
        case "font-size":
            guard let size = Double(value), size.isFinite, size >= 6.0, size <= 72.0 else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Font size must be a finite number between 6 and 72")
            }
        case "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic":
            let family = unquoted(value)
            guard !family.trimmingCharacters(in: .whitespaces).isEmpty && isControlFree(family) else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Font family must be non-empty and control-free")
            }
        case "font-style", "font-style-bold", "font-style-italic", "font-style-bold-italic":
            let style = unquoted(value)
            guard isControlFree(style) else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Font style must be control-free")
            }
        case "font-synthetic-style":
            guard isValidFontSyntheticStyle(value) else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Invalid font-synthetic-style value")
            }
        case "font-feature":
            if !value.isEmpty {
                guard isValidFontFeatureList(value) else {
                    throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Invalid font-feature list")
                }
            }
        case "adjust-cell-width", "adjust-cell-height", "adjust-font-baseline", "adjust-underline-position", "adjust-underline-thickness":
            if !value.isEmpty {
                guard isValidMetricModifier(value) else {
                    throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Invalid metric modifier")
                }
            }
        case "cursor-opacity", "background-opacity":
            guard let d = Double(value), d.isFinite, d >= 0, d <= 1 else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Opacity must be a finite number between 0 and 1")
            }
        case "cursor-thickness":
            guard let d = Double(value), d.isFinite, d > 0 else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Cursor thickness must be a positive finite number")
            }
        case "background-blur", "background-blur-radius":
            guard let i = Int(value), i >= 0 else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Background blur must be a non-negative integer")
            }
        case "cell-width", "cell_width", "cell-height", "cell_height":
            guard let d = Double(value), d.isFinite, d > 0 else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Cell dimension must be a positive finite number")
            }
        case "window-padding-x", "window-padding-y":
            guard isValidPaddingPair(value) else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Padding must be a non-negative number or comma-separated pair")
            }
        case "window-padding-balance", "selection-invert-fg-bg", "cursor-style-blink":
            guard isValidBool(value) else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Expected 'true' or 'false'")
            }
        case "window-padding-color":
            guard TerminalTheme.WindowPaddingColor(rawValue: value) != nil else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Invalid window-padding-color")
            }
        case "window-colorspace":
            guard TerminalTheme.ColorSpace(rawValue: value) != nil else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Invalid window-colorspace")
            }
        case "cursor-style":
            guard ["block", "block_hollow", "bar", "underline"].contains(value) else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Invalid cursor-style")
            }
        case "grapheme-width-method":
            guard ["unicode", "legacy"].contains(value) else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Invalid grapheme-width-method")
            }
        case "custom-shader":
            guard isControlFree(value) else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Custom shader path contains control characters")
            }
        case "custom-shader-animation":
            guard ["true", "false", "always"].contains(value) else {
                throw ThemePresetError.invalidValue(line: lineNum, key: key, value: value, reason: "Invalid custom-shader-animation")
            }
        default:
            if key.hasPrefix("tab-status-color-") {
                let state = String(key.dropFirst("tab-status-color-".count))
                guard ["working", "waiting", "done", "error", "idle"].contains(state) else {
                    throw ThemePresetError.unknownKey(line: lineNum, "Unknown tab status state '\(state)'")
                }
                guard isValidRGBColor(value) else {
                    throw ThemePresetError.invalidColor(line: lineNum, key: key, value)
                }
            } else {
                throw ThemePresetError.unknownKey(line: lineNum, "Unknown appearance key '\(key)'")
            }
        }
    }

    public static func isValidRGBColor(_ value: String) -> Bool {
        var hex = value.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") {
            hex = String(hex.dropFirst())
        }
        guard hex.count == 6 else { return false }
        return hex.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    public static func isControlFree(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7F {
                return false
            }
        }
        return true
    }

    public static func unquoted(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func isValidBool(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t == "true" || t == "false"
    }

    private static func isValidPaddingPair(_ value: String) -> Bool {
        let parts = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return false }
        return true
    }

    private static func isValidMetricModifier(_ value: String) -> Bool {
        if value.hasSuffix("%") {
            guard let percent = Double(value.dropLast()), percent.isFinite else { return false }
            return true
        } else {
            guard Int(value) != nil else { return false }
            return true
        }
    }

    private static func isValidFontSyntheticStyle(_ value: String) -> Bool {
        if value == "true" || value == "false" { return true }
        let parts = value.split(separator: ",")
        guard !parts.isEmpty else { return false }
        for raw in parts {
            var name = raw.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("no-") { name.removeFirst(3) }
            guard ["bold", "italic", "bold-italic"].contains(name) else { return false }
        }
        return true
    }

    private static func isValidFontFeatureList(_ value: String) -> Bool {
        let items = value.split(separator: ",")
        guard !items.isEmpty else { return false }
        for item in items {
            var text = Substring(item.trimmingCharacters(in: .whitespaces))
            if text.hasPrefix("+") || text.hasPrefix("-") {
                text.removeFirst()
            }
            var tag = text
            var setting: Substring?
            if let split = text.firstIndex(where: { $0 == "=" || $0 == " " }) {
                tag = text[..<split]
                setting = text[text.index(after: split)...]
            }
            let name = String(tag).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard name.count == 4, name.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
                return false
            }
            if let setting {
                let word = setting.trimmingCharacters(in: CharacterSet(charactersIn: " ="))
                switch word {
                case "on", "off": break
                default:
                    guard let number = Int(word), number >= 0 else { return false }
                }
            }
        }
        return true
    }
}
