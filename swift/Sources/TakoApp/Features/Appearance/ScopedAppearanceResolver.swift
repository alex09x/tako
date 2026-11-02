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
    /// Resolves the effective theme in order:
    /// 1. Optional workspace theme preset over global (`applyingTheme` preserves fonts).
    /// 2. Workspace explicit fields.
    /// 3. Optional pane theme preset over current theme (`applyingTheme` preserves fonts).
    /// 4. Pane explicit fields.
    public static func resolve(
        global: TerminalTheme,
        workspaceOverrides: [String: String]?,
        paneOverrides: [String: String]?,
        themeSearchPaths: [String] = TerminalTheme.themeSearchPaths
    ) -> TerminalTheme {
        var theme = global

        // 1. Optional workspace theme preset
        if let ws = workspaceOverrides {
            if let preset = ws[AppearanceKey.theme.rawValue] {
                theme = theme.applyingTheme(named: preset, searchPaths: themeSearchPaths)
            }
            // 2. Workspace explicit fields
            applyExplicitFields(overrides: ws, to: &theme)
        }

        // 3. Optional pane theme preset
        if let pane = paneOverrides {
            if let preset = pane[AppearanceKey.theme.rawValue] {
                theme = theme.applyingTheme(named: preset, searchPaths: themeSearchPaths)
            }
            // 4. Pane explicit fields
            applyExplicitFields(overrides: pane, to: &theme)
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
