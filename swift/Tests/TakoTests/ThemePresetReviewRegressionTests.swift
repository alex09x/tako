/*
 * tako — Preset review regressions
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@MainActor @Suite(.serialized) struct ThemePresetReviewRegressionTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func legacyCopyKeepsExtendedPaletteAndPreservesUnsupportedLinesAsNotes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let builtins = root.appendingPathComponent("builtins")
        try FileManager.default.createDirectory(at: builtins, withIntermediateDirectories: true)
        let text = "# legacy notes\nbackground = #123456\nbackground = invalid\ncursor-text = #ffffff\npalette = 200=#010203\npalette = 1=#111111\npalette = 1=#222222\n"
        let original = builtins.appendingPathComponent("Legacy")
        try text.write(to: original, atomically: true, encoding: .utf8)
        let store = ThemePresetStore(directory: root.appendingPathComponent("user"), searchPaths: [builtins.path])
        let loaded = try store.load(named: "Legacy")
        let editor = ThemePresetEditor(store: store, original: loaded, base: .takoDefault, copyName: "Converted")
        let saved = try editor.save()
        #expect(saved.config.contains("# legacy notes"))
        #expect(saved.config.contains("# Imported legacy (not applied): cursor-text = #ffffff"))
        #expect(ThemePresetConfig.value(for: "palette:200", in: saved.config) == "#010203")
        #expect(ThemePresetConfig.value(for: "palette:1", in: saved.config) == "#222222")
        #expect(ThemePresetConfig.value(for: "background", in: saved.config) == "#123456")
        #expect(try ThemePresetConfig.parsed(saved.config).palette[200] == TerminalTheme.parseColor("#010203"))
        #expect(try String(contentsOf: original, encoding: .utf8) == text)
    }

    @Test func reopeningSettingsClosesEditorAndItsScopedParent() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        try "command = /bin/sh\n".write(to: config, atomically: true, encoding: .utf8)
        let context = ScopedAppearanceContext(scope: .workspace(UUID()), title: "Workspace",
            store: ScopedAppearanceStore(fileURL: root.appendingPathComponent("styles.json")), globalTheme: { .takoDefault })
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        TerminalSettingsDialog.show(in: window, configPath: config.path, tab: .themes, appearance: context)
        let parent = try #require(window.contentView?.subviews.compactMap { $0 as? TerminalSettingsDialog }.first)
        parent.beginPresetEditor(createNew: true)
        #expect(window.contentView?.subviews.compactMap { $0 as? TerminalSettingsDialog }.count == 2)
        TerminalSettingsDialog.show(in: window, configPath: config.path, tab: .keybindings)
        let remaining = window.contentView?.subviews.compactMap { $0 as? TerminalSettingsDialog } ?? []
        #expect(remaining.count == 1)
        #expect(remaining.first?.presetEditor == nil && remaining.first?.scopedAppearance == nil)
        #expect(remaining.first?.activeTab == .keybindings)
    }

    @Test func largeTerminalFontDoesNotPushSettingsControlsOutsideTheWindow() {
        var theme = TerminalTheme.takoDefault
        theme.fontSize = 72
        let style = TerminalSettingsDialog.Style.from(theme)
        #expect(style.font.pointSize == 13)
        let dialog = TerminalSettingsDialog(style: style, initialTab: .themes)
        dialog.frame = NSRect(x: 0, y: 0, width: 800, height: 650)
        #expect(dialog.cardRect.minX >= 0 && dialog.cardRect.maxX <= dialog.bounds.maxX)
    }
}
