/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import Foundation

/// Pure helpers for theme preset configuration format, parsing, and serialization.
public enum ThemePresetConfig {
    public static let marker = "# tako-preset-version: 1"

    public static let defaultBackgroundHex = "#14100e"
    public static let defaultForegroundHex = "#ede6df"
    public static let defaultCursorHex = "#f4581c"
    public static let defaultSelectionHex = "#352b23"
    public static let defaultFontFamily = "Menlo"
    public static let defaultFontSize: CGFloat = 13
    public static let defaultCursorStyle = "block"
    public static let defaultCursorBlink = "true"

    public static let defaultPaletteHex: [Int: String] = [
        0: "#1d1f21",
        1: "#cc6666",
        2: "#b5bd68",
        3: "#f0c674",
        4: "#81a2be",
        5: "#b294bb",
        6: "#8abeb7",
        7: "#c5c8c6",
        8: "#666666",
        9: "#d54e53",
        10: "#b9ca4a",
        11: "#e7c547",
        12: "#7aa6da",
        13: "#c397d8",
        14: "#70c0b1",
        15: "#eaeaea",
    ]

    /// Extract the value for an ordinary key or synthetic key (e.g. `palette:0` through `palette:15`).
    public static func value(for key: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        if key.hasPrefix("palette:"),
           let index = Int(key.dropFirst("palette:".count)),
           (0...15).contains(index) {
            for line in lines.reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                guard let eq = trimmed.firstIndex(of: "=") else { continue }
                let k = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                if k == "palette" {
                    let v = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    let parts = v.split(separator: "=", maxSplits: 1)
                    if parts.count >= 2,
                       let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       idx == index {
                        return parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            return nil
        } else {
            for line in lines.reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                guard let eq = trimmed.firstIndex(of: "=") else { continue }
                let k = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                if k == key {
                    return unquoted(String(trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
                }
            }
            return nil
        }
    }

    /// Update or remove (when value is nil) an ordinary key or synthetic palette key in text.
    /// Preserves unrelated configurations and comments.
    public static func setting(_ value: String?, for key: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let hadTrailingNewline = text.hasSuffix("\n")
        if hadTrailingNewline && lines.last == "" {
            lines.removeLast()
        }

        if key.hasPrefix("palette:"),
           let index = Int(key.dropFirst("palette:".count)),
           (0...15).contains(index) {
            var foundIndex: Int?
            var lastPaletteLineIndex: Int?

            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                guard let eq = trimmed.firstIndex(of: "=") else { continue }
                let k = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                if k == "palette" {
                    lastPaletteLineIndex = i
                    let v = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    let parts = v.split(separator: "=", maxSplits: 1)
                    if parts.count >= 1,
                       let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       idx == index {
                        foundIndex = i
                    }
                }
            }

            if let val = value {
                let newLine = "palette = \(index)=\(val)"
                if let found = foundIndex {
                    lines[found] = newLine
                } else if let last = lastPaletteLineIndex {
                    lines.insert(newLine, at: last + 1)
                } else {
                    lines.append(newLine)
                }
            } else if let found = foundIndex {
                lines.remove(at: found)
            }
        } else {
            var foundIndex: Int?
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                guard let eq = trimmed.firstIndex(of: "=") else { continue }
                let k = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                if k == key {
                    foundIndex = i
                }
            }

            if let val = value {
                let newLine = "\(key) = \(val)"
                if let found = foundIndex {
                    lines[found] = newLine
                } else {
                    lines.append(newLine)
                }
            } else if let found = foundIndex {
                lines.remove(at: found)
            }
        }

        var result = lines.joined(separator: "\n")
        if hadTrailingNewline || !result.isEmpty {
            result.append("\n")
        }
        return result
    }

    /// Parse configuration text into a TerminalTheme.
    public static func parsed(_ text: String, configPath: String? = nil) throws -> TerminalTheme {
        let complete = prepareForSave(text)
        try validate(complete)
        return TerminalTheme.parse(config: complete, base: .takoDefault, honourTheme: false, configPath: configPath)
    }

    /// Serialize a TerminalTheme into a standalone theme preset configuration string.
    public static func configuration(from theme: TerminalTheme) -> String {
        var lines: [String] = []
        lines.append(marker)

        lines.append("background = \(hex(for: theme.background))")
        lines.append("foreground = \(hex(for: theme.foreground))")
        lines.append("cursor-color = \(hex(for: theme.cursorColor))")
        lines.append("selection-background = \(hex(for: theme.selectionBackground))")

        if let selFg = theme.selectionForeground {
            lines.append("selection-foreground = \(hex(for: selFg))")
        }

        let cursorStyle: String
        switch theme.cursorShape {
        case .block: cursorStyle = "block"
        case .bar: cursorStyle = "bar"
        case .underline: cursorStyle = "underline"
        }
        lines.append("cursor-style = \(cursorStyle)")
        lines.append("cursor-style-blink = \(theme.cursorBlink ? "true" : "false")")

        let family = theme.fontFamily?.trimmingCharacters(in: .whitespaces)
        let resolvedFamily = (family != nil && !family!.isEmpty) ? family! : defaultFontFamily
        lines.append("font-family = \(resolvedFamily)")

        let formattedSize = theme.fontSize.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(theme.fontSize))"
            : "\(theme.fontSize)"
        lines.append("font-size = \(formattedSize)")
        lines += typographyConfiguration(from: theme)

        for i in 0...15 {
            let colorHex = theme.palette[i].map(hex(for:)) ?? defaultPaletteHex[i]!
            lines.append("palette = \(i)=\(colorHex)")
        }

        if theme.selectionInvertFgBg {
            lines.append("selection-invert-fg-bg = true")
        }
        if theme.cursorOpacity != 1.0 {
            lines.append("cursor-opacity = \(theme.cursorOpacity)")
        }
        if let thickness = theme.cursorThickness {
            let formatted = thickness.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(thickness))"
                : "\(thickness)"
            lines.append("cursor-thickness = \(formatted)")
        }
        if theme.backgroundOpacity != 1.0 {
            lines.append("background-opacity = \(theme.backgroundOpacity)")
        }
        if theme.backgroundBlur > 0 {
            lines.append("background-blur = \(theme.backgroundBlur)")
        }
        if theme.windowPaddingBalance {
            lines.append("window-padding-balance = true")
        }
        if theme.windowPaddingColor != .background {
            lines.append("window-padding-color = \(theme.windowPaddingColor.rawValue)")
        }
        if theme.windowColorSpace != .srgb {
            lines.append("window-colorspace = \(theme.windowColorSpace.rawValue)")
        }
        if theme.graphemeWidthMethod != .unicode {
            lines.append("grapheme-width-method = \(theme.graphemeWidthMethod == .legacy ? "legacy" : "unicode")")
        }
        for (state, color) in theme.tabStatusColors.sorted(by: { $0.key < $1.key }) {
            lines.append("tab-status-color-\(state) = \(hex(for: color))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Prepares a configuration for storage: ensures marker and fills omitted essential defaults.
    static func prepareForSave(_ text: String) -> String {
        var working = text

        let hasVersionLine = working.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("# tako-preset-version:")
        }
        if !hasVersionLine {
            working = marker + "\n" + working
        }

        if value(for: "background", in: working) == nil {
            working = setting(defaultBackgroundHex, for: "background", in: working)
        }
        if value(for: "foreground", in: working) == nil {
            working = setting(defaultForegroundHex, for: "foreground", in: working)
        }
        if value(for: "cursor-color", in: working) == nil {
            working = setting(defaultCursorHex, for: "cursor-color", in: working)
        }
        if value(for: "selection-background", in: working) == nil {
            working = setting(defaultSelectionHex, for: "selection-background", in: working)
        }
        if value(for: "cursor-style", in: working) == nil {
            working = setting(defaultCursorStyle, for: "cursor-style", in: working)
        }
        if value(for: "cursor-style-blink", in: working) == nil {
            working = setting(defaultCursorBlink, for: "cursor-style-blink", in: working)
        }
        if value(for: "font-family", in: working) == nil {
            working = setting(defaultFontFamily, for: "font-family", in: working)
        }
        if value(for: "font-size", in: working) == nil {
            working = setting("\(Int(defaultFontSize))", for: "font-size", in: working)
        }
        for i in 0...15 {
            if value(for: "palette:\(i)", in: working) == nil {
                working = setting(defaultPaletteHex[i]!, for: "palette:\(i)", in: working)
            }
        }

        return working
    }

    public static func hex(for color: CGColor) -> String {
        let srgbColor = color.converted(to: srgbSpace, intent: .defaultIntent, options: nil) ?? color
        guard let c = srgbColor.components, !c.isEmpty else {
            return "#000000"
        }
        let r: Int
        let g: Int
        let b: Int
        if c.count >= 3 {
            r = min(255, max(0, Int((c[0] * 255.0).rounded())))
            g = min(255, max(0, Int((c[1] * 255.0).rounded())))
            b = min(255, max(0, Int((c[2] * 255.0).rounded())))
        } else {
            let gray = min(255, max(0, Int((c[0] * 255.0).rounded())))
            r = gray
            g = gray
            b = gray
        }
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
