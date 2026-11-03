/*
 * tako — Numeric typography controls within a complete theme
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension TerminalSettingRegistry {
    public static let fontWeightSettings: [TerminalSettingItem] = [
        ("font-weight", "Regular weight", 400),
        ("font-weight-bold", "Bold weight", 700),
        ("font-weight-italic", "Italic weight", 400),
        ("font-weight-bold-italic", "Bold italic weight", 700)
    ].map { key, title, value in
        TerminalSettingItem(id: key, title: title, category: "Font weight",
            type: .number(defaultValue: value, min: 100, max: 900, step: 50),
            description: "CSS weight 100–900 · arrows change by 50; Config accepts any integer. Variable fonts use their weight axis; other fonts use the closest face.")
    }
}
