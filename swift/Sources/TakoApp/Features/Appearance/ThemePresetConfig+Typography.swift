/*
 * tako — Preserve a preset's complete typography and layout
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension ThemePresetConfig {
    static func typographyConfiguration(from theme: TerminalTheme) -> [String] {
        var lines: [String] = []
        for (key, family) in [("font-family-bold", theme.fontFamilyBold), ("font-family-italic", theme.fontFamilyItalic),
                              ("font-family-bold-italic", theme.fontFamilyBoldItalic)] {
            if let family { lines.append("\(key) = \(family)") }
        }
        for (key, style) in [("font-style", theme.fontStyle), ("font-style-bold", theme.fontStyleBold),
                             ("font-style-italic", theme.fontStyleItalic), ("font-style-bold-italic", theme.fontStyleBoldItalic)] {
            switch style {
            case .default: break
            case .disabled: lines.append("\(key) = false")
            case .named(let name): lines.append("\(key) = \(name)")
            }
        }
        if theme.fontSyntheticStyle != .all {
            let entries: [(String, TerminalTheme.FontSyntheticStyle)] = [("bold", .bold), ("italic", .italic), ("bold-italic", .boldItalic)]
            let disabled = entries.filter { !theme.fontSyntheticStyle.contains($0.1) }.map { "no-" + $0.0 }
            lines.append("font-synthetic-style = \(disabled.joined(separator: ","))")
        }
        for feature in theme.fontFeatures {
            lines.append("font-feature = \(feature.tag)=\(feature.value)")
        }
        for (key, value) in [("cell-width", theme.cellWidth), ("cell-height", theme.cellHeight)] {
            if let value { lines.append("\(key) = \(value)") }
        }
        for (key, modifier) in [("adjust-cell-width", theme.adjustCellWidth), ("adjust-cell-height", theme.adjustCellHeight),
                                ("adjust-font-baseline", theme.adjustFontBaseline), ("adjust-underline-position", theme.adjustUnderlinePosition),
                                ("adjust-underline-thickness", theme.adjustUnderlineThickness)] {
            switch modifier {
            case .points(let amount): lines.append("\(key) = \(amount)")
            case .percent(let amount): lines.append("\(key) = \(amount)%")
            case nil: break
            }
        }
        lines.append("window-padding-x = \(theme.padding.left),\(theme.padding.right)")
        lines.append("window-padding-y = \(theme.padding.top),\(theme.padding.bottom)")
        for shader in theme.customShaders { lines.append("custom-shader = \(shader)") }
        let animation: String
        switch theme.customShaderAnimation {
        case .disabled: animation = "false"
        case .enabled: animation = "true"
        case .always: animation = "always"
        }
        lines.append("custom-shader-animation = \(animation)")
        return lines
    }
}
