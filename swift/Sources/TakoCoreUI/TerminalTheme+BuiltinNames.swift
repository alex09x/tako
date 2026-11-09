/*
 * tako — Compatibility names for bundled terminal themes
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension TerminalTheme {
    /// These two built-in names appeared in an unpublished desktop preview.
    /// Keep saved configurations readable while presenting English catalog names.
    public static func canonicalThemeName(_ name: String) -> String {
        let oldDark = "\u{41a}\u{43e}\u{43d}\u{442}\u{440}\u{430}\u{441}\u{442}"
        let oldLight = oldDark + " \u{441}\u{432}\u{435}\u{442}\u{43b}\u{430}\u{44f}"
        switch name {
        case oldDark: return "High Contrast"
        case oldLight: return "High Contrast Light"
        default: return name
        }
    }
}
