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

/// Descriptor for a named terminal theme preset.
public struct ThemePreset: Equatable, Sendable {
    public let name: String
    public let config: String
    public let isUser: Bool

    public init(name: String, config: String, isUser: Bool) {
        self.name = name
        self.config = config
        self.isUser = isUser
    }
}

extension Notification.Name {
    /// Published when theme presets are saved or modified in the user preset store.
    public static let takoThemePresetsDidChange = Notification.Name("takoThemePresetsDidChange")
}

/// Errors thrown by theme preset configuration parsing and store operations.
public enum ThemePresetError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case invalidName(String)
    case notFound(String)
    case presetAlreadyExists(String)
    case cannotShadowBuiltin(String)
    case readOnlyBuiltin(String)
    case staleOverwrite(String)
    case symlinkNotAllowed(String)
    case unsupportedVersion(String)
    case malformedLine(line: Int, String)
    case unknownKey(line: Int, String)
    case duplicateKey(line: Int, String)
    case invalidPaletteIndex(line: Int, String)
    case invalidColor(line: Int, key: String, String)
    case invalidValue(line: Int, key: String, value: String, reason: String)
    case nestedThemeNotAllowed(line: Int, String)
    case persistenceFailed(String)

    public var errorDescription: String? {
        description
    }

    public var description: String {
        switch self {
        case .invalidName(let message):
            return "Invalid preset name: \(message)"
        case .notFound(let message):
            return "Theme preset not found: \(message)"
        case .presetAlreadyExists(let message):
            return "Theme preset already exists: \(message)"
        case .cannotShadowBuiltin(let message):
            return "Cannot shadow built-in theme: \(message)"
        case .readOnlyBuiltin(let message):
            return "Built-in theme is read-only: \(message)"
        case .staleOverwrite(let message):
            return "Stale overwrite refused: \(message)"
        case .symlinkNotAllowed(let message):
            return "Symbolic link not allowed: \(message)"
        case .unsupportedVersion(let message):
            return "Unsupported preset marker version: \(message)"
        case .malformedLine(let line, let message):
            return "Line \(line): Malformed configuration: \(message)"
        case .unknownKey(let line, let message):
            return "Line \(line): Unknown non-appearance key: \(message)"
        case .duplicateKey(let line, let message):
            return "Line \(line): Duplicate key: \(message)"
        case .invalidPaletteIndex(let line, let message):
            return "Line \(line): Invalid palette index: \(message)"
        case .invalidColor(let line, let key, let value):
            return "Line \(line): Invalid color '\(value)' for key '\(key)'"
        case .invalidValue(let line, let key, let value, let reason):
            return "Line \(line): Invalid value '\(value)' for key '\(key)': \(reason)"
        case .nestedThemeNotAllowed(let line, let message):
            return "Line \(line): Nested theme references are not allowed: \(message)"
        case .persistenceFailed(let message):
            return "Preset persistence failed: \(message)"
        }
    }
}
