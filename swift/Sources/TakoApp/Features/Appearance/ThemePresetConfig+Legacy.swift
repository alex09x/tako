/*
 * tako — Copy legacy color themes without losing their notes
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension ThemePresetConfig {
    static func isVersioned(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("# tako-preset-version:")
        }
    }

    /// Keep supported values and all comments. Unsupported/invalid legacy
    /// entries become notes rather than preventing the user from copying a
    /// theme that already renders. Last ordinary value wins, as at runtime.
    static func legacyDraft(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        func identity(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { return nil }
            let key = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
            if key == "font-feature" || key == "custom-shader" { return nil }
            if key == "palette" {
                let value = trimmed[trimmed.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                return "palette:" + String(value.split(separator: "=", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
            }
            return key
        }
        var last: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            if (try? validate(line)) != nil, let key = identity(line) { last[key] = index }
        }
        return lines.enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return line }
            if (try? validate(line)) == nil { return "# Imported legacy (not applied): " + line }
            if let key = identity(line), last[key] != index { return "# Superseded legacy: " + line }
            return line
        }.joined(separator: "\n")
    }
}
