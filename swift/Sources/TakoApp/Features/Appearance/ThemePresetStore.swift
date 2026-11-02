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

/// Main actor store for managing theme presets on disk.
///
/// Gives priority to user presets, protects built-in themes against shadowing or mutation,
/// and enforces atomic writes and stale-overwrite prevention.
@MainActor
public final class ThemePresetStore {
    public let directory: URL
    public let searchPaths: [String]

    public init(directory: URL, searchPaths: [String] = TerminalTheme.themeSearchPaths) {
        self.directory = directory
        self.searchPaths = searchPaths
    }

    /// Load a theme preset by name. User directory has first priority, followed by search paths.
    public func load(named name: String) throws -> ThemePreset {
        try Self.validatePresetName(name)

        if Self.isSymbolicLink(at: directory) {
            throw ThemePresetError.symlinkNotAllowed("Preset directory is a symbolic link: '\(directory.path)'")
        }

        // 1. User preset directory has first priority
        let userURL = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: userURL.path) {
            if Self.isSymbolicLink(at: userURL) {
                throw ThemePresetError.symlinkNotAllowed("Theme preset file is a symbolic link: '\(userURL.path)'")
            }
            let text = try String(contentsOf: userURL, encoding: .utf8)
            if ThemePresetConfig.isVersioned(text) { try ThemePresetConfig.validate(text) }
            return ThemePreset(name: name, config: text, isUser: true)
        }

        // 2. Built-in files elsewhere
        let standardizedDir = directory.standardizedFileURL.path
        for searchDir in searchPaths {
            let expandedDir = (searchDir as NSString).expandingTildeInPath
            let searchURL = URL(fileURLWithPath: expandedDir).standardizedFileURL
            guard searchURL.path != standardizedDir else { continue }
            let candidateURL = searchURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                if Self.isSymbolicLink(at: candidateURL) {
                    throw ThemePresetError.symlinkNotAllowed("Built-in theme file is a symbolic link: '\(candidateURL.path)'")
                }
                let text = try String(contentsOf: candidateURL, encoding: .utf8)
                if ThemePresetConfig.isVersioned(text) { try ThemePresetConfig.validate(text) }
                return ThemePreset(name: name, config: text, isUser: false)
            }
        }

        throw ThemePresetError.notFound("Theme preset '\(name)' not found")
    }

    /// Save a theme preset to the user directory.
    ///
    /// Validates preset name and configuration, ensures marker and essential defaults,
    /// checks for built-in shadowing and stale overwrites, writes atomically, and posts
    /// `Notification.Name.takoThemePresetsDidChange`.
    public func save(name: String, config: String, replacing: ThemePreset? = nil) throws -> ThemePreset {
        try Self.validateWritableName(name)

        if Self.isSymbolicLink(at: directory) {
            throw ThemePresetError.symlinkNotAllowed("Preset directory is a symbolic link: '\(directory.path)'")
        }

        if isBuiltinFile(named: name) {
            throw ThemePresetError.cannotShadowBuiltin("Cannot shadow built-in theme '\(name)'")
        }

        let targetURL = directory.appendingPathComponent(name)
        if Self.isSymbolicLink(at: targetURL) {
            throw ThemePresetError.symlinkNotAllowed("Target file is a symbolic link: '\(targetURL.path)'")
        }

        let targetExists = FileManager.default.fileExists(atPath: targetURL.path)

        if let replacing = replacing {
            if !replacing.isUser && replacing.name == name {
                throw ThemePresetError.readOnlyBuiltin("Built-in theme '\(name)' is read-only")
            }

            if replacing.isUser && replacing.name == name {
                guard targetExists else {
                    throw ThemePresetError.notFound("Existing preset '\(name)' to replace does not exist on disk")
                }
                let currentDisk = try String(contentsOf: targetURL, encoding: .utf8)
                guard currentDisk == replacing.config else {
                    throw ThemePresetError.staleOverwrite("Preset '\(name)' on disk does not match original descriptor text")
                }
            } else if targetExists {
                throw ThemePresetError.presetAlreadyExists("Theme preset '\(name)' already exists")
            }
        } else if targetExists {
            throw ThemePresetError.presetAlreadyExists("Theme preset '\(name)' already exists")
        }

        let prepared = ThemePresetConfig.prepareForSave(config)
        try ThemePresetConfig.validate(prepared)

        let parent = directory
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        guard let data = prepared.data(using: .utf8) else {
            throw ThemePresetError.persistenceFailed("Failed to encode preset to UTF-8")
        }

        try data.write(to: targetURL, options: .atomic)

        NotificationCenter.default.post(name: .takoThemePresetsDidChange, object: self)

        return ThemePreset(name: name, config: prepared, isUser: true)
    }

    // MARK: - Validation & Filesystem Helpers

    /// Rename first makes an exact alias, preserving even legacy theme
    /// semantics. Both files remain valid until references have moved.
    func copyForRename(_ original: ThemePreset, to name: String) throws -> ThemePreset {
        try Self.validateWritableName(name)
        guard original.isUser else { throw ThemePresetError.readOnlyBuiltin(original.name) }
        let current = try load(named: original.name)
        guard current.isUser, current.config == original.config else { throw ThemePresetError.staleOverwrite(original.name) }
        guard !isBuiltinFile(named: name) else { throw ThemePresetError.cannotShadowBuiltin(name) }
        let target = directory.appendingPathComponent(name)
        guard !Self.isSymbolicLink(at: target) else { throw ThemePresetError.symlinkNotAllowed(name) }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ThemePresetError.presetAlreadyExists(name) }
        try Data(original.config.utf8).write(to: target, options: .atomic)
        NotificationCenter.default.post(name: .takoThemePresetsDidChange, object: self)
        return ThemePreset(name: name, config: original.config, isUser: true)
    }

    /// Removal is recoverable. Hidden backups do not appear in the catalog.
    func remove(_ original: ThemePreset) throws -> URL {
        guard original.isUser else { throw ThemePresetError.readOnlyBuiltin(original.name) }
        let current = try load(named: original.name)
        guard current.isUser else { throw ThemePresetError.readOnlyBuiltin(original.name) }
        guard current.config == original.config else { throw ThemePresetError.staleOverwrite(original.name) }
        let recovery = directory.appendingPathComponent(".deleted", isDirectory: true)
        guard !Self.isSymbolicLink(at: recovery) else { throw ThemePresetError.symlinkNotAllowed(recovery.path) }
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = recovery.appendingPathComponent(UUID().uuidString + ".theme")
        try FileManager.default.moveItem(at: directory.appendingPathComponent(original.name), to: backup)
        NotificationCenter.default.post(name: .takoThemePresetsDidChange, object: self)
        return backup
    }

    public static func validatePresetName(_ name: String) throws {
        guard !name.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ThemePresetError.invalidName("Preset name cannot be empty or whitespace-only")
        }
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ThemePresetError.invalidName("Preset name cannot start or end with whitespace")
        }
        guard !name.hasPrefix(".") else {
            throw ThemePresetError.invalidName("Preset name cannot start with a dot: '\(name)'")
        }
        guard !name.contains("/"), !name.contains("\\") else {
            throw ThemePresetError.invalidName("Preset name cannot contain slashes: '\(name)'")
        }
        guard !name.contains("..") else {
            throw ThemePresetError.invalidName("Preset name cannot contain path traversal: '\(name)'")
        }
        for scalar in name.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) || scalar.value < 0x20 || scalar.value == 0x7F {
                throw ThemePresetError.invalidName("Preset name cannot contain control characters: '\(name)'")
            }
        }
    }

    private static func validateWritableName(_ name: String) throws {
        try validatePresetName(name)
        guard name.lowercased() != "tako" else { throw ThemePresetError.cannotShadowBuiltin("tako is the reserved TakoCore alias") }
        guard !(name.hasPrefix("\"") && name.hasSuffix("\"")) && !(name.hasPrefix("'") && name.hasSuffix("'")) else {
            throw ThemePresetError.invalidName("Do not wrap the stored name in literal quotes")
        }
    }

    public static func isSymbolicLink(at url: URL) -> Bool {
        var statBuf = stat()
        if lstat(url.path, &statBuf) == 0 {
            return (statBuf.st_mode & S_IFMT) == S_IFLNK
        }
        return false
    }

    private func isBuiltinFile(named name: String) -> Bool {
        let standardizedDir = directory.standardizedFileURL.path
        for searchDir in searchPaths {
            let expandedDir = (searchDir as NSString).expandingTildeInPath
            let searchURL = URL(fileURLWithPath: expandedDir).standardizedFileURL
            guard searchURL.path != standardizedDir else { continue }
            let candidateURL = searchURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                return true
            }
        }
        return false
    }
}
