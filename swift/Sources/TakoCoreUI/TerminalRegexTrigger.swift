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

/// User-defined passive regex trigger rule for output text highlighting or notifications (E7).
/// Strictly passive: never injects keystrokes, commands, or automated input into the terminal.
public struct TerminalRegexTrigger: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let pattern: String
    public let regex: NSRegularExpression?
    public let action: Action
    public let colorName: String?
    public let color: NSColor?
    public let style: HighlightStyle
    public let notificationTitle: String?
    public let onlyUnfocused: Bool
    public let isDynamic: Bool

    public enum Action: String, Codable, Sendable, CaseIterable {
        case highlight
        case notify
        case both

        public var highlights: Bool { self == .highlight || self == .both }
        public var notifies: Bool { self == .notify || self == .both }
    }

    public enum HighlightStyle: String, Codable, Sendable, CaseIterable {
        case background
        case underline
        case box
        case bold
    }

    /// Validates whether a regex pattern is safe from catastrophic backtracking (ReDoS).
    /// Rejects nested quantifiers (e.g. (a+)+, (a*)*), pathological repetitions, and patterns over 512 chars.
    public static func isSafePattern(_ pattern: String) -> (isSafe: Bool, reason: String?) {
        guard pattern.count <= 512 else {
            return (false, "pattern exceeds maximum allowed length of 512 characters")
        }

        var depth = 0
        var groupHasQuantifier: [Bool] = []
        let chars = Array(pattern)
        var i = 0
        var escaped = false

        while i < chars.count {
            let c = chars[i]
            if escaped {
                escaped = false
                i += 1
                continue
            }
            if c == "\\" {
                escaped = true
                i += 1
                continue
            }

            if c == "(" {
                depth += 1
                groupHasQuantifier.append(false)
            } else if c == ")" {
                if depth > 0 {
                    let hadQuantifierInside = groupHasQuantifier.removeLast()
                    depth -= 1
                    let nextIndex = i + 1
                    if nextIndex < chars.count {
                        let nextChar = chars[nextIndex]
                        if nextChar == "+" || nextChar == "*" || nextChar == "{" {
                            if hadQuantifierInside {
                                return (false, "pathological regex: nested quantifier on group causes exponential backtracking")
                            }
                        }
                    }
                }
            } else if c == "+" || c == "*" || c == "{" {
                if depth > 0 && !groupHasQuantifier.isEmpty {
                    groupHasQuantifier[groupHasQuantifier.count - 1] = true
                }
            }
            i += 1
        }

        return (true, nil)
    }

    public init?(
        id: UUID = UUID(),
        pattern: String,
        action: Action = .highlight,
        colorName: String? = nil,
        color: NSColor? = nil,
        style: HighlightStyle = .background,
        notificationTitle: String? = nil,
        onlyUnfocused: Bool = true,
        isDynamic: Bool = false
    ) {
        guard Self.isSafePattern(pattern).isSafe,
              let compiled = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        self.id = id
        self.pattern = pattern
        self.regex = compiled
        self.action = action
        self.colorName = colorName
        let resolved = color ?? colorName.flatMap(Self.resolveColor(named:))
        self.color = resolved ?? .systemYellow
        self.style = style
        self.notificationTitle = notificationTitle
        self.onlyUnfocused = onlyUnfocused
        self.isDynamic = isDynamic
    }

    public static func == (lhs: TerminalRegexTrigger, rhs: TerminalRegexTrigger) -> Bool {
        lhs.id == rhs.id &&
        lhs.pattern == rhs.pattern &&
        lhs.action == rhs.action &&
        lhs.colorName == rhs.colorName &&
        lhs.style == rhs.style &&
        lhs.notificationTitle == rhs.notificationTitle &&
        lhs.onlyUnfocused == rhs.onlyUnfocused &&
        lhs.isDynamic == rhs.isDynamic
    }

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

public extension Notification.Name {
    static let passiveTriggersDidChange = Notification.Name("passiveTriggersDidChange")
}
#endif
