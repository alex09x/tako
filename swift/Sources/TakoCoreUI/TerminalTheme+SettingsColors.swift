/*
 * tako — Terminal appearance colors
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics

extension TerminalTheme {
    /// Resolve the displayed color after theme and explicit config overrides.
    public func settingsColor(for key: String) -> CGColor? {
        switch key {
        case "background": return background
        case "foreground": return foreground
        case "cursor-color": return cursorColor
        case "selection-background": return selectionBackground
        default:
            guard key.hasPrefix("tab-status-color-") else { return nil }
            return tabStatusColors[String(key.dropFirst("tab-status-color-".count))]
        }
    }
}
