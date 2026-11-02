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

/// Scope targeted by an appearance override: an entire workspace or a single pane.
public enum AppearanceScope: Equatable, Hashable, Sendable {
    case workspace(UUID)
    case pane(UUID)
}

/// Permitted appearance keys.
public enum AppearanceKey: String, CaseIterable, Sendable {
    case theme = "theme"
    case fontFamily = "font-family"
    case fontSize = "font-size"
    case background = "background"
    case foreground = "foreground"
    case cursorColor = "cursor-color"
    case selectionBackground = "selection-background"
}

/// Errors thrown by scoped appearance operations.
public enum AppearanceStoreError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case invalidKey(String)
    case invalidValue(key: String, value: String, reason: String)
    case corruptedFile(URL, String)
    case unsupportedVersion(Int, URL)
    case persistenceFailed(String)

    public var errorDescription: String? {
        description
    }

    public var description: String {
        switch self {
        case .invalidKey(let key):
            return "Unsupported appearance key '\(key)'. Allowed keys: theme, font-family, font-size, background, foreground, cursor-color, selection-background."
        case .invalidValue(let key, let value, let reason):
            return "Invalid value '\(value)' for key '\(key)': \(reason)."
        case .corruptedFile(let url, let reason):
            return "Appearance file at '\(url.path)' is corrupt: \(reason). Writes refused to prevent data loss."
        case .unsupportedVersion(let version, let url):
            return "Appearance file at '\(url.path)' has unsupported version \(version). Writes refused to prevent data loss."
        case .persistenceFailed(let message):
            return "Failed to persist appearance state: \(message)."
        }
    }
}

/// Input validators for appearance keys.
public enum AppearanceValidator {
    /// Nonempty and control-free names (preserves user theme and font names with spaces).
    public static func isValidName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                return false
            }
        }
        return true
    }

    /// Valid six-digit RGB color hex string (e.g. "#112233" or "112233").
    public static func isValidRGBColor(_ value: String) -> Bool {
        var hex = value
        if hex.hasPrefix("#") {
            hex = String(hex.dropFirst())
        }
        guard hex.count == 6 else { return false }
        return hex.allSatisfy { char in
            char.isHexDigit && char.isASCII
        }
    }

    /// Finite font size between 6 and 72 inclusive.
    public static func isValidFontSize(_ value: String) -> Bool {
        guard let size = Double(value.trimmingCharacters(in: .whitespaces)),
              size.isFinite,
              size >= 6.0,
              size <= 72.0 else {
            return false
        }
        return true
    }

    public static func validate(value: String, for key: AppearanceKey) throws {
        switch key {
        case .theme:
            guard isValidName(value) else {
                throw AppearanceStoreError.invalidValue(key: key.rawValue, value: value, reason: "Theme name must be non-empty and control-free")
            }
        case .fontFamily:
            guard isValidName(value) else {
                throw AppearanceStoreError.invalidValue(key: key.rawValue, value: value, reason: "Font family must be non-empty and control-free")
            }
        case .fontSize:
            guard isValidFontSize(value) else {
                throw AppearanceStoreError.invalidValue(key: key.rawValue, value: value, reason: "Font size must be a finite number between 6 and 72")
            }
        case .background, .foreground, .cursorColor, .selectionBackground:
            guard isValidRGBColor(value) else {
                throw AppearanceStoreError.invalidValue(key: key.rawValue, value: value, reason: "Color must be a valid 6-digit RGB hex string")
            }
        }
    }
}

extension Notification.Name {
    /// Broadcast when scoped appearance overrides are mutated.
    public static let takoScopedAppearanceDidChange = Notification.Name("takoScopedAppearanceDidChange")
}
