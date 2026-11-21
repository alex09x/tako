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
import CoreGraphics

/// Resolves the effective terminal theme across global configuration, workspace overrides,
/// and pane overrides according to the precedence hierarchy.
public enum ScopedAppearanceResolver {
    /// Resolves the effective theme over global, then each present scope in
    /// order workspace -> session -> pane. Every scope applies its optional
    /// full theme preset (`applyingTheme` preserves fonts unless the preset
    /// defines typography) and then its explicit fields, so a child's
    /// explicit field always beats any parent's preset or field.
    public static func resolve(
        global: TerminalTheme,
        workspaceOverrides: [String: String]?,
        sessionOverrides: [String: String]? = nil,
        paneOverrides: [String: String]?,
        themeSearchPaths: [String] = TerminalTheme.themeSearchPaths,
        themeOverrides: [String: TerminalTheme] = [:]
    ) -> TerminalTheme {
        var theme = global
        for layer in [workspaceOverrides, sessionOverrides, paneOverrides] {
            guard let layer else { continue }
            if let preset = layer[AppearanceKey.theme.rawValue] {
                theme = themeOverrides[preset] ?? theme.applyingTheme(named: preset, searchPaths: themeSearchPaths)
            }
            applyExplicitFields(overrides: layer, to: &theme)
        }
        return theme
    }

    private static func applyExplicitFields(overrides: [String: String], to theme: inout TerminalTheme) {
        if let family = overrides[AppearanceKey.fontFamily.rawValue] {
            theme.fontFamily = family
        }
        if let sizeStr = overrides[AppearanceKey.fontSize.rawValue],
           let size = Double(sizeStr.trimmingCharacters(in: .whitespaces)),
           size.isFinite, size >= 6, size <= 72 {
            if theme.fontSize > 0 {
                let scale = CGFloat(size) / theme.fontSize
                theme.cellWidth = theme.cellWidth.map { $0 * scale }
                theme.cellHeight = theme.cellHeight.map { $0 * scale }
            }
            theme.fontSize = CGFloat(size)
        }
        if let bgStr = overrides[AppearanceKey.background.rawValue],
           let color = TerminalTheme.parseColor(bgStr) {
            theme.background = color
        }
        if let fgStr = overrides[AppearanceKey.foreground.rawValue],
           let color = TerminalTheme.parseColor(fgStr) {
            theme.foreground = color
        }
        if let cursorStr = overrides[AppearanceKey.cursorColor.rawValue],
           let color = TerminalTheme.parseColor(cursorStr) {
            theme.cursorColor = color
        }
        if let selBgStr = overrides[AppearanceKey.selectionBackground.rawValue],
           let color = TerminalTheme.parseColor(selBgStr) {
            theme.selectionBackground = color
        }
    }
}
