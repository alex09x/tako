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
}

public extension Notification.Name {
    static let passiveTriggersDidChange = Notification.Name("passiveTriggersDidChange")
}
#endif
