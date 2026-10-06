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

extension TerminalTheme {
    /// Every theme name available on this machine, sorted.
    public static func availableThemes() -> [String] {
        var names = Set<String>()
        for dir in themeSearchPaths {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in contents where !name.hasPrefix(".") {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    /// Load a theme by name and apply it on top of `self`. A theme file is
    /// the same `key = value` syntax as a config, so it reuses the parser.
    public func applyingTheme(named name: String) -> TerminalTheme {
        applyingTheme(named: name, searchPaths: Self.themeSearchPaths)
    }

    func applyingTheme(named name: String, searchPaths: [String]) -> TerminalTheme {
        for dir in searchPaths {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var merged = Self.parse(
                config: text,
                base: self,
                honourTheme: false,
                themeSearchPaths: searchPaths)
            // A theme sets colors; it must not clobber the user's font or
            // padding choices, which live in the config proper.
            merged.fontFamily = fontFamily
            merged.fontSize = fontSize
            merged.cellWidth = cellWidth
            merged.cellHeight = cellHeight
            merged.padding = padding
            merged.fontFamilyBold = fontFamilyBold
            merged.fontFamilyItalic = fontFamilyItalic
            merged.fontFamilyBoldItalic = fontFamilyBoldItalic
            merged.fontStyle = fontStyle
            merged.fontStyleBold = fontStyleBold
            merged.fontStyleItalic = fontStyleItalic
            merged.fontStyleBoldItalic = fontStyleBoldItalic
            merged.fontSyntheticStyle = fontSyntheticStyle
            merged.fontFeatures = fontFeatures
            merged.adjustCellWidth = adjustCellWidth
            merged.adjustCellHeight = adjustCellHeight
            merged.adjustFontBaseline = adjustFontBaseline
            merged.adjustUnderlinePosition = adjustUnderlinePosition
            merged.adjustUnderlineThickness = adjustUnderlineThickness
            merged.windowPaddingBalance = windowPaddingBalance
            merged.windowPaddingColor = windowPaddingColor
            merged.windowColorSpace = windowColorSpace
            merged.customShaders = customShaders
            merged.customShaderAnimation = customShaderAnimation
            return merged
        }
        return self
    }

    /// Parse a config file's appearance keys: `key = value` lines, `#`
    /// comments. Keys that are not about appearance are ignored.
    /// `configPath` is the file the text came from; relative
    /// `custom-shader` paths are resolved against its directory.
    public static func parse(config text: String,
                             base: TerminalTheme = TerminalTheme(),
                             honourTheme: Bool = true,
                             configPath: String? = nil) -> TerminalTheme {
        parse(
            config: text,
            base: base,
            honourTheme: honourTheme,
            themeSearchPaths: Self.themeSearchPaths,
            configPath: configPath)
    }

    static func parse(config text: String,
                      base: TerminalTheme,
                      honourTheme: Bool,
                      themeSearchPaths: [String],
                      configPath: String? = nil) -> TerminalTheme {
        var entries: [(key: String, value: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            entries.append((String(key), String(value)))
        }

        // Tako applies the selected theme first, then overlays every
        // explicit setting in the config regardless of textual order.
        let themeName = honourTheme
            ? entries.last(where: { $0.key == "theme" })?.value
            : nil
        var theme = themeName.map {
            base.applyingTheme(named: $0, searchPaths: themeSearchPaths)
        } ?? base

        for (key, value) in entries {
            switch key {
            case "background":
                if let c = parseColor(value) { theme.background = c }
            case "foreground":
                if let c = parseColor(value) { theme.foreground = c }
            case "selection-background":
                if let c = parseColor(value) { theme.selectionBackground = c }
            case "selection-foreground":
                if let c = parseColor(value) { theme.selectionForeground = c }
            case "selection-invert-fg-bg":
                if let b = parseBool(value) { theme.selectionInvertFgBg = b }
            case "cursor-color":
                if let c = parseColor(value) { theme.cursorColor = c }
            case "cursor-opacity":
                if let d = Double(value), d.isFinite { theme.cursorOpacity = min(max(d, 0), 1) }
            case "cursor-thickness":
                if let d = Double(value), d.isFinite, d > 0 { theme.cursorThickness = CGFloat(d) }
            case "background-opacity":
                if let d = Double(value) { theme.backgroundOpacity = min(max(d, 0), 1) }
            case "background-blur", "background-blur-radius":
                if let i = Int(value) { theme.backgroundBlur = i }
            case "font-family":
                theme.fontFamily = value
            case "font-size":
                if let d = Double(value) { theme.fontSize = CGFloat(d) }
            case "cell-width", "cell_width":
                if let d = Double(value) { theme.cellWidth = CGFloat(d) }
            case "cell-height", "cell_height":
                if let d = Double(value) { theme.cellHeight = CGFloat(d) }
            case "font-family-bold":
                theme.fontFamilyBold = family(value)
            case "font-family-italic":
                theme.fontFamilyItalic = family(value)
            case "font-family-bold-italic":
                theme.fontFamilyBoldItalic = family(value)
            case "font-style":
                theme.fontStyle = FontStyle(configValue: unquoted(value))
            case "font-style-bold":
                theme.fontStyleBold = FontStyle(configValue: unquoted(value))
            case "font-style-italic":
                theme.fontStyleItalic = FontStyle(configValue: unquoted(value))
            case "font-style-bold-italic":
                theme.fontStyleBoldItalic = FontStyle(configValue: unquoted(value))
            case "font-synthetic-style":
                if let style = FontSyntheticStyle(configValue: value) { theme.fontSyntheticStyle = style }
            case "font-feature":
                if value.isEmpty {
                    theme.fontFeatures = []
                } else if let features = FontFeature.parseList(value) {
                    for feature in features {
                        theme.fontFeatures.removeAll { $0.tag == feature.tag }
                        theme.fontFeatures.append(feature)
                    }
                }
            case "adjust-cell-width":
                parseModifier(value, into: &theme.adjustCellWidth)
            case "adjust-cell-height":
                parseModifier(value, into: &theme.adjustCellHeight)
            case "adjust-font-baseline":
                parseModifier(value, into: &theme.adjustFontBaseline)
            case "adjust-underline-position":
                parseModifier(value, into: &theme.adjustUnderlinePosition)
            case "adjust-underline-thickness":
                parseModifier(value, into: &theme.adjustUnderlineThickness)
            case "window-padding-x":
                if let pair = TerminalPadding.pair(value) { (theme.padding.left, theme.padding.right) = pair }
            case "window-padding-y":
                if let pair = TerminalPadding.pair(value) { (theme.padding.top, theme.padding.bottom) = pair }
            case "window-padding-balance":
                if let b = parseBool(value) { theme.windowPaddingBalance = b }
            case "window-padding-color":
                if let c = WindowPaddingColor(rawValue: value) { theme.windowPaddingColor = c }
            case "window-colorspace":
                if let c = ColorSpace(rawValue: value) { theme.windowColorSpace = c }
            case "cursor-style-blink":
                theme.cursorBlink = (value != "false")
            case "cursor-style":
                switch value {
                case "block", "block_hollow": theme.cursorShape = .block
                case "bar": theme.cursorShape = .bar
                case "underline": theme.cursorShape = .underline
                default: break
                }
            case "grapheme-width-method":
                switch value {
                case "unicode": theme.graphemeWidthMethod = .unicode
                case "legacy": theme.graphemeWidthMethod = .legacy
                default: break
                }
            case "custom-shader":
                if value.isEmpty {
                    theme.customShaders = []
                } else {
                    theme.customShaders.append(shaderPath(unquoted(value), configPath: configPath))
                }
            case "custom-shader-animation":
                if let animation = TerminalCustomShaderAnimation(configValue: value) {
                    theme.customShaderAnimation = animation
                }
            case "theme":
                continue
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                   let color = parseColor(String(parts[1])) {
                    theme.palette[index] = color
                }
            default:
                continue
            }
        }
        return theme
    }

    /// `path` with `~` expanded and, when relative, anchored at the
    /// directory of `configPath`.
    static func shaderPath(_ path: String, configPath: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/"), let configPath else { return expanded }
        let directory = (configPath as NSString).deletingLastPathComponent
        return ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    private static func parseModifier(_ value: String, into modifier: inout MetricModifier?) {
        if value.isEmpty {
            modifier = nil
        } else if let parsed = MetricModifier(configValue: value) {
            modifier = parsed
        }
    }

    private static func family(_ value: String) -> String? {
        let name = unquoted(value)
        return name.isEmpty ? nil : name
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    static func parseBool(_ s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespaces) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// `#rrggbb`, `rrggbb`, or `r,g,b` -- the forms Tako configs use.
    public static func parseColor(_ s: String) -> CGColor? {
        var text = s.trimmingCharacters(in: .whitespaces)
        if text.contains(",") {
            let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 else { return nil }
            return srgb(parts[0] / 255, parts[1] / 255, parts[2] / 255, 1)
        }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return srgb(CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255, 1)
    }

    /// Load the user's config: the application-support file first, then the
    /// XDG files, which win.
    public static func loadUserConfig() -> TerminalTheme {
        let paths = [
            "~/Library/Application Support/com.tako-core.terminal/config",
            "~/.config/tako-core/config",
            "~/.config/tako/config",
        ].map { ($0 as NSString).expandingTildeInPath }
        return loadUserConfig(paths: paths, themeSearchPaths: Self.themeSearchPaths)
    }

    /// Each existing file in `paths` is parsed on top of the previous result,
    /// so a later file overrides an earlier one, `theme` included.
    static func loadUserConfig(paths: [String], themeSearchPaths: [String]) -> TerminalTheme {
        var theme = TerminalTheme.takoDefault
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            theme = parse(
                config: text,
                base: theme,
                honourTheme: true,
                themeSearchPaths: themeSearchPaths,
                configPath: path)
        }
        return theme
    }
}
