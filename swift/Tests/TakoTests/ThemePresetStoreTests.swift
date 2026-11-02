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
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct ThemePresetStoreTests {

    private func createTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ThemePresetStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Roundtrip Complete Values

    @Test func roundtripCompleteValues() throws {
        let userDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: userDir) }

        var theme = TerminalTheme.takoDefault
        theme.background = try ThemePresetConfig.parsed("background = #1a1b26").background
        theme.foreground = try ThemePresetConfig.parsed("foreground = #c0caf5").foreground
        theme.cursorColor = try ThemePresetConfig.parsed("cursor-color = #ff007c").cursorColor
        theme.selectionBackground = try ThemePresetConfig.parsed("selection-background = #33467c").selectionBackground
        theme.selectionForeground = try ThemePresetConfig.parsed("selection-foreground = #ffffff").selectionForeground
        theme.fontFamily = "Courier New"
        theme.fontSize = 15
        theme.cursorShape = .bar
        theme.cursorBlink = false
        for i in 0...15 {
            let hex = String(format: "#%02x%02x%02x", i * 16, i * 16, i * 16)
            theme.palette[i] = try ThemePresetConfig.parsed("palette = \(i)=\(hex)").palette[i]
        }

        let serialized = ThemePresetConfig.configuration(from: theme)
        try ThemePresetConfig.validate(serialized)

        let parsed = try ThemePresetConfig.parsed(serialized)
        #expect(ThemePresetConfig.hex(for: parsed.background) == "#1a1b26")
        #expect(ThemePresetConfig.hex(for: parsed.foreground) == "#c0caf5")
        #expect(ThemePresetConfig.hex(for: parsed.cursorColor) == "#ff007c")
        #expect(ThemePresetConfig.hex(for: parsed.selectionBackground) == "#33467c")
        #expect(parsed.selectionForeground != nil)
        #expect(ThemePresetConfig.hex(for: parsed.selectionForeground!) == "#ffffff")
        #expect(parsed.fontFamily == "Courier New")
        #expect(parsed.fontSize == 15)
        #expect(parsed.cursorShape == .bar)
        #expect(parsed.cursorBlink == false)

        for i in 0...15 {
            let expected = String(format: "#%02x%02x%02x", i * 16, i * 16, i * 16)
            let actual = parsed.palette[i].map(ThemePresetConfig.hex(for:))
            #expect(actual == expected)
        }

        let store = ThemePresetStore(directory: userDir, searchPaths: [])
        let saved = try store.save(name: "RoundtripTheme", config: serialized)
        #expect(saved.name == "RoundtripTheme")
        #expect(saved.isUser == true)

        let loaded = try store.load(named: "RoundtripTheme")
        #expect(loaded == saved)
    }

    // MARK: - Palette Editing

    @Test func paletteEditing() throws {
        let initial = """
        # Initial config
        background = #112233
        palette = 0=#000000
        palette = 1=#111111
        palette = 2=#222222
        """

        #expect(ThemePresetConfig.value(for: "palette:1", in: initial) == "#111111")
        #expect(ThemePresetConfig.value(for: "palette:5", in: initial) == nil)

        let updated = ThemePresetConfig.setting("#00ff00", for: "palette:1", in: initial)
        #expect(ThemePresetConfig.value(for: "palette:1", in: updated) == "#00ff00")
        #expect(ThemePresetConfig.value(for: "palette:0", in: updated) == "#000000")
        #expect(ThemePresetConfig.value(for: "palette:2", in: updated) == "#222222")

        let withNewIndex = ThemePresetConfig.setting("#abcdef", for: "palette:5", in: updated)
        #expect(ThemePresetConfig.value(for: "palette:5", in: withNewIndex) == "#abcdef")
        #expect(ThemePresetConfig.value(for: "palette:1", in: withNewIndex) == "#00ff00")

        let removed = ThemePresetConfig.setting(nil, for: "palette:1", in: withNewIndex)
        #expect(ThemePresetConfig.value(for: "palette:1", in: removed) == nil)
        #expect(ThemePresetConfig.value(for: "palette:0", in: removed) == "#000000")
        #expect(ThemePresetConfig.value(for: "palette:2", in: removed) == "#222222")
        #expect(ThemePresetConfig.value(for: "palette:5", in: removed) == "#abcdef")
    }

    // MARK: - Comments Preservation

    @Test func commentsPreservation() throws {
        let text = """
        # tako-preset-version: 1
        # Author: Test Author
        background = #123456
        # The following is font size
        font-size = 14
        """

        let updated = ThemePresetConfig.setting("#654321", for: "background", in: text)
        #expect(updated.contains("# Author: Test Author"))
        #expect(updated.contains("# The following is font size"))
        #expect(updated.contains("background = #654321"))
        #expect(updated.contains("font-size = 14"))
    }

    // MARK: - Copy Builtin vs User Replace

    @Test func copyBuiltinVsUserReplace() throws {
        let root = try createTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userDir = root.appendingPathComponent("user")
        let builtinDir = root.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: builtinDir, withIntermediateDirectories: true)

        let builtinNordPath = builtinDir.appendingPathComponent("Nord")
        let nordConfig = """
        background = #2e3440
        foreground = #d8dee9
        cursor-color = #88c0d0
        selection-background = #434c5e
        font-family = Menlo
        font-size = 13
        """
        try nordConfig.write(to: builtinNordPath, atomically: true, encoding: .utf8)

        let store = ThemePresetStore(directory: userDir, searchPaths: [builtinDir.path])

        let loadedBuiltin = try store.load(named: "Nord")
        #expect(loadedBuiltin.name == "Nord")
        #expect(loadedBuiltin.isUser == false)

        // Overwriting a built-in with same name must fail
        #expect(throws: ThemePresetError.self) {
            try store.save(name: "Nord", config: nordConfig, replacing: loadedBuiltin)
        }

        // Copying builtin under a new name succeeds
        let userCopy = try store.save(name: "MyNord", config: loadedBuiltin.config, replacing: loadedBuiltin)
        #expect(userCopy.name == "MyNord")
        #expect(userCopy.isUser == true)
        #expect(FileManager.default.fileExists(atPath: userDir.appendingPathComponent("MyNord").path))
        #expect(FileManager.default.fileExists(atPath: builtinNordPath.path))

        // Updating user preset succeeds
        let updatedConfig = ThemePresetConfig.setting("#000000", for: "background", in: userCopy.config)
        let replacedUser = try store.save(name: "MyNord", config: updatedConfig, replacing: userCopy)
        #expect(replacedUser.name == "MyNord")
        #expect(ThemePresetConfig.value(for: "background", in: replacedUser.config) == "#000000")
    }

    // MARK: - Name Collisions

    @Test func nameCollisions() throws {
        let root = try createTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let userDir = root.appendingPathComponent("user")
        let builtinDir = root.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: builtinDir, withIntermediateDirectories: true)

        try "background = #111111\n".write(to: builtinDir.appendingPathComponent("BuiltinTheme"), atomically: true, encoding: .utf8)

        let store = ThemePresetStore(directory: userDir, searchPaths: [builtinDir.path])
        _ = try store.save(name: "ExistingUser", config: "background = #222222\n")

        // Collision with existing user preset without replacing
        #expect(throws: ThemePresetError.self) {
            try store.save(name: "ExistingUser", config: "background = #333333\n", replacing: nil)
        }

        // Collision shadowing a built-in theme
        #expect(throws: ThemePresetError.self) {
            try store.save(name: "BuiltinTheme", config: "background = #333333\n", replacing: nil)
        }
    }

    // MARK: - Symlink, Traversal, and Control Names

    @Test func symlinkTraversalAndControlNames() throws {
        let userDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let store = ThemePresetStore(directory: userDir, searchPaths: [])

        let invalidNames = ["", "   ", ".", "..", ".hidden", "sub/dir", "../parent", "theme\u{07}", "theme\n1", "a\\b", "a\0b"]
        for invalid in invalidNames {
            #expect(throws: ThemePresetError.self) { try store.load(named: invalid) }
            #expect(throws: ThemePresetError.self) { try store.save(name: invalid, config: "background = #111111") }
        }

        // Names with ordinary spaces are valid
        let spacedPreset = try store.save(name: "My Spaced Theme", config: "background = #123456")
        #expect(spacedPreset.name == "My Spaced Theme")
        let loadedSpaced = try store.load(named: "My Spaced Theme")
        #expect(loadedSpaced.name == "My Spaced Theme")

        // Target file is a symlink
        let realFile = userDir.appendingPathComponent("RealFile")
        try "background = #111111\n".write(to: realFile, atomically: true, encoding: .utf8)
        let symlinkFile = userDir.appendingPathComponent("SymlinkFile")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)

        #expect(throws: ThemePresetError.self) { try store.load(named: "SymlinkFile") }
        #expect(throws: ThemePresetError.self) { try store.save(name: "SymlinkFile", config: "background = #222222") }

        // Store directory itself is a symlink
        let outerDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: outerDir) }
        let symlinkDir = outerDir.appendingPathComponent("SymlinkDir")
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: userDir)

        let storeWithSymlinkDir = ThemePresetStore(directory: symlinkDir, searchPaths: [])
        #expect(throws: ThemePresetError.self) { try storeWithSymlinkDir.load(named: "RealFile") }
        #expect(throws: ThemePresetError.self) { try storeWithSymlinkDir.save(name: "NewInSymlinkDir", config: "background = #333333") }
    }

    // MARK: - Stale Editing

    @Test func staleEditing() throws {
        let userDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let store = ThemePresetStore(directory: userDir, searchPaths: [])
        let original = try store.save(name: "PresetDoc", config: "background = #112233\n")

        // External modification
        let fileURL = userDir.appendingPathComponent("PresetDoc")
        try "background = #999999\n".write(to: fileURL, atomically: true, encoding: .utf8)

        // Stale overwrite refused
        #expect(throws: ThemePresetError.self) {
            try store.save(name: "PresetDoc", config: "background = #445566\n", replacing: original)
        }
    }

    // MARK: - Invalid Config and Unknown Version

    @Test func invalidConfigAndUnknownVersion() throws {
        let invalidConfigs = [
            "# tako-preset-version: 2\nbackground = #112233",
            "background = #111111\nbackground = #222222",
            "palette = 1=#111111\npalette = 1=#222222",
            "background = #12345",
            "background = blue",
            "palette = 16=#112233",
            "palette = -1=#112233",
            "font-size = 4",
            "font-size = 75",
            "font-family = \"\"",
            "font-family = Menlo\u{07}",
            "theme = AnotherTheme",
            "background #112233",
            "non-appearance-knob = true",
        ]

        for config in invalidConfigs {
            #expect(throws: ThemePresetError.self) {
                try ThemePresetConfig.validate(config)
            }
        }
    }

    // MARK: - Failed Write Preserves Old File

    @Test func failedWritePreservesOldFile() throws {
        let userDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let store = ThemePresetStore(directory: userDir, searchPaths: [])
        let preset = try store.save(name: "ExistingPreset", config: "background = #112233\n")

        let fileURL = userDir.appendingPathComponent("ExistingPreset")
        let originalContent = try String(contentsOf: fileURL, encoding: .utf8)

        // 1. Validation failure preserves disk content
        #expect(throws: ThemePresetError.self) {
            try store.save(name: "ExistingPreset", config: "background = invalidColor", replacing: preset)
        }
        let afterValidationFailure = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(afterValidationFailure == originalContent)

        // 2. Unwritable directory preserves disk content
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: userDir.path)
        #expect(throws: Error.self) {
            try store.save(name: "ExistingPreset", config: "background = #445566\n", replacing: preset)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: userDir.path)

        let afterPermissionsFailure = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(afterPermissionsFailure == originalContent)
    }

    // MARK: - Notification on Save

    @Test func notificationOnSave() throws {
        let userDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let store = ThemePresetStore(directory: userDir, searchPaths: [])
        var notificationReceived = false

        let observer = NotificationCenter.default.addObserver(
            forName: .takoThemePresetsDidChange,
            object: store,
            queue: nil
        ) { _ in
            notificationReceived = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try store.save(name: "NotifiedPreset", config: "background = #123456\n")
        #expect(notificationReceived == true)
    }
}
