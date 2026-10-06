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
#if canImport(AppKit)
import AppKit

extension TerminalRegexTrigger {
    /// Resolves a color name or hex code to an NSColor.
    public static func resolveColor(named name: String) -> NSColor? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch clean {
        case "red": return .systemRed
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "yellow": return .systemYellow
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "magenta", "pink": return .systemPink
        case "cyan", "teal": return .systemTeal
        case "white": return .white
        case "gray", "grey": return .systemGray
        default:
            if let cg = TerminalTheme.parseColor(clean) {
                return NSColor(cgColor: cg)
            }
            return nil
        }
    }

    /// Parses a configuration line into a TerminalRegexTrigger.
    /// Supported formats:
    /// 1. `<pattern> = <action>[:<color>[:<style>[:<title>]]]`
    /// 2. `<pattern>` (defaults to highlight:yellow:background)
    public static func parse(line: String) -> TerminalRegexTrigger? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let pattern: String
        let specPart: String?

        if let eqIndex = trimmed.firstIndex(of: "=") {
            pattern = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            specPart = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            pattern = trimmed
            specPart = nil
        }

        guard !pattern.isEmpty else { return nil }

        var action: Action = .highlight
        var colorName: String? = "yellow"
        var style: HighlightStyle = .background
        var title: String? = nil

        if let spec = specPart, !spec.isEmpty {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let first = parts.first, !first.isEmpty {
                action = Action(rawValue: first.lowercased()) ?? .highlight
            }
            if parts.count > 1, !parts[1].isEmpty {
                colorName = parts[1]
            }
            if parts.count > 2, !parts[2].isEmpty {
                style = HighlightStyle(rawValue: parts[2].lowercased()) ?? .background
            }
            if parts.count > 3, !parts[3].isEmpty {
                title = parts[3]
            }
        }

        return TerminalRegexTrigger(
            pattern: pattern,
            action: action,
            colorName: colorName,
            style: style,
            notificationTitle: title,
            onlyUnfocused: true,
            isDynamic: false
        )
    }
}
#endif
