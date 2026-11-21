// tako — Terminal emulator
// Copyright (c) 2026 Alexander Panasenko
//
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import Foundation

extension TerminalTheme {
    /// Resolve the configured light/dark pair before looking up a theme file.
    /// Ordinary names remain literal, including names containing commas.
    public static func themeName(for selection: String, darkAppearance: Bool) -> String {
        let entries = selection.split(separator: ",", omittingEmptySubsequences: false)
        guard entries.count == 2 else { return selection }
        var names: [String: String] = [:]
        for entry in entries {
            guard let colon = entry.firstIndex(of: ":") else { return selection }
            let key = entry[..<colon].trimmingCharacters(in: .whitespaces)
            let name = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard (key == "light" || key == "dark"), !name.isEmpty, names[key] == nil else { return selection }
            names[key] = name
        }
        guard names["light"] != nil, names["dark"] != nil else { return selection }
        return names[darkAppearance ? "dark" : "light"]!
    }
}
