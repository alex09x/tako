/*
 * tako — Full theme editing and inheritance regressions
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
@testable import TakoKit

@MainActor @Suite(.serialized)
struct FullThemePresetTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func fullPresetOwnsFontsWhileLegacyColorThemePreservesThem() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ThemePresetStore(directory: root, searchPaths: [])
        _ = try store.save(name: "Complete", config: "font-family = Monaco\nfont-size = 21\nbackground = #123456\n")
        try "background = #abcdef\nfont-size = 30\n".write(to: root.appendingPathComponent("Legacy"), atomically: true, encoding: .utf8)
        var parent = TerminalTheme.takoDefault
        parent.fontFamily = "Menlo"
        parent.fontSize = 17
        let full = parent.applyingTheme(named: "Complete", searchPaths: [root.path])
        #expect(full.fontFamily == "Monaco" && full.fontSize == 21)
        #expect(full.background == TerminalTheme.parseColor("#123456"))
        let legacy = parent.applyingTheme(named: "Legacy", searchPaths: [root.path])
        #expect(legacy.fontFamily == "Menlo" && legacy.fontSize == 17)
        #expect(TerminalTheme.presetContainsTypography(named: "Complete", searchPaths: [root.path]))
    }

    @Test func selectingFullThemeClearsOnlyAppearanceOverridesAndReadsItsFontSize() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let themes = root.appendingPathComponent("themes")
        let store = ThemePresetStore(directory: themes, searchPaths: [])
        _ = try store.save(name: "Full", config: "font-family = Monaco\nfont-size = 20\nforeground = #112233\n")
        let path = root.appendingPathComponent("config")
        let original = "font-size = 13\nfont-family = Menlo\nforeground = #ffffff\npalette = 1=#abcdef\ncommand = /bin/sh\nkeybind = cmd+k=clear_screen\n# keep this comment\n"
        try original.write(to: path, atomically: true, encoding: .utf8)
        let file = KeybindConfigFile(configPath: path.path)
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: file, initialTab: .themes)
        let item = TerminalAppearanceCatalog.themeItems(["Full"])[0]
        dialog.applyAppearanceChoice(item)
        let saved = try String(contentsOf: path, encoding: .utf8)
        #expect(saved.contains("command = /bin/sh") && saved.contains("keybind = cmd+k=clear_screen"))
        #expect(saved.contains("# keep this comment") && saved.contains("theme = Full"))
        #expect(!saved.contains("font-size = 13") && !saved.contains("foreground = #ffffff") && !saved.contains("palette ="))
        dialog.switchTab(to: .fontSize)
        #expect(dialog.effectiveSettingValue(for: dialog.filteredSettingItems[0]) == "20")
        #expect(file.effectiveSettingValue(for: TerminalAppearanceCatalog.fontItems([])[0]) == "Monaco")
    }

    @Test func selectingFullWorkspacePresetLeavesOtherPaneOverridesAndGlobalConfigUntouched() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let themes = root.appendingPathComponent("themes")
        _ = try ThemePresetStore(directory: themes, searchPaths: []).save(name: "Owned", config: "font-size = 22\n")
        let config = root.appendingPathComponent("config")
        try "font-size = 15\n".write(to: config, atomically: true, encoding: .utf8)
        let styles = ScopedAppearanceStore(fileURL: root.appendingPathComponent("styles.json"), themeSearchPaths: [themes.path])
        let workspace = UUID(), other = UUID()
        try styles.setValue("17", for: "font-size", scope: .workspace(workspace))
        try styles.setValue("#ffffff", for: "foreground", scope: .workspace(workspace))
        try styles.setValue("40", for: "font-size", scope: .pane(other))
        let context = ScopedAppearanceContext(scope: .workspace(workspace), title: "Workspace", store: styles, globalTheme: { .takoDefault })
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: KeybindConfigFile(configPath: config.path), initialTab: .themes, appearance: context)
        dialog.applyAppearanceChoice(TerminalAppearanceCatalog.themeItems(["Owned"])[0])
        #expect(styles.value(for: "font-size", scope: .workspace(workspace)) == nil)
        #expect(styles.value(for: "foreground", scope: .workspace(workspace)) == nil)
        #expect(context.effectiveTheme.fontSize == 22)
        #expect(styles.value(for: "font-size", scope: .pane(other)) == "40")
        #expect(try String(contentsOf: config, encoding: .utf8) == "font-size = 15\n")
    }

    @Test func completeTypographyAndLayoutSurviveSerialization() throws {
        let text = """
        font-family = "Menlo"
        font-family-bold = Monaco
        font-family-italic = Courier
        font-style-bold = Medium
        font-synthetic-style = no-italic
        font-feature = calt=0
        font-feature = liga=1
        cell-width = 9
        cell-height = 19
        adjust-font-baseline = -1
        window-padding-x = 3,7
        window-padding-y = 5,9
        """
        let theme = try ThemePresetConfig.parsed(text)
        let encoded = ThemePresetConfig.configuration(from: theme)
        let decoded = try ThemePresetConfig.parsed(encoded)
        #expect(decoded.fontFamily == "Menlo" && decoded.fontFamilyBold == "Monaco" && decoded.fontFamilyItalic == "Courier")
        #expect(decoded.fontStyleBold == .named("Medium"))
        #expect(decoded.fontSyntheticStyle == theme.fontSyntheticStyle && decoded.fontFeatures == theme.fontFeatures)
        #expect(decoded.cellWidth == 9 && decoded.cellHeight == 19 && decoded.adjustFontBaseline == .points(-1))
        #expect(decoded.padding == theme.padding)
        #expect(decoded.palette.count == 16)
    }

    @Test func commentContainingMarkerDoesNotSuppressRealVersionHeader() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try ThemePresetStore(directory: root, searchPaths: []).save(name: "Header", config: "# Notes about # tako-preset-version: 1\nfont-size = 19\n")
        #expect(saved.config.hasPrefix(ThemePresetConfig.marker + "\n"))
        #expect(TerminalTheme.presetContainsTypography(named: saved.name, searchPaths: [root.path]))
    }

    @Test func omittedPaletteEntriesSerializeTheRealEngineDefaults() {
        let (surface, window) = hostedSurface(theme: .takoDefault)
        defer { window.close() }
        let text = (0..<16).map { "\u{1b}[38;5;\($0)mX" }.joined()
        surface.core.feed(bytes: Data(("\u{1b}[2J\u{1b}[H" + text).utf8))
        let cells = surface.core.viewportRow(row: 0)
        for index in 0..<16 {
            let cell = cells[index]
            let actual = String(format: "#%02x%02x%02x", Int(cell.fgR), Int(cell.fgG), Int(cell.fgB))
            #expect(actual == ThemePresetConfig.defaultPaletteHex[index])
        }
    }

    @Test func previewAndCancelRestoreActualSurfaceAndKeepCore() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config")
        try "command = /bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        let parent = TerminalSettingsDialog(style: .from(nil), configFile: KeybindConfigFile(configPath: file.path))
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        surface.close()
        surface.updateTheme(.takoDefault)
        let before = surface.theme
        let originalCellWidth = surface.cellWidth
        let core = surface.core
        let preview = ThemePresetPreview(owner: parent, targets: [surface])
        var changed = before
        changed.fontSize = 26
        changed.background = TerminalTheme.parseColor("#123456")!
        preview.apply(changed)
        #expect(surface.theme.fontSize == 26 && surface.theme.background == changed.background)
        #expect(surface.core === core)
        #expect(surface.cellWidth > originalCellWidth)
        ThemePresetPreview.restoreAll()
        #expect(surface.theme.fontSize == before.fontSize && surface.theme.background == before.background)
        #expect(surface.core === core)
        #expect(try String(contentsOf: file, encoding: .utf8) == "command = /bin/sh\n")
    }

    @Test func failedSaveRollsBackPreviewAndKeepsDraftOpen() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        try "sentinel".write(to: blocked, atomically: true, encoding: .utf8)
        let parent = TerminalSettingsDialog(style: .from(nil))
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        surface.close()
        let before = surface.theme
        let editor = ThemePresetEditor(store: ThemePresetStore(directory: blocked, searchPaths: []), original: nil,
            base: before, copyName: "Cannot save")
        editor.setValue("#123456", for: "background")
        editor.preview = ThemePresetPreview(owner: parent, targets: [surface])
        let dialog = TerminalSettingsDialog(style: .from(nil), editor: editor)
        dialog.previewPreset()
        #expect(surface.theme.background == TerminalTheme.parseColor("#123456"))
        dialog.savePreset()
        #expect(!dialog.isWithdrawing)
        #expect((dialog.accessibilityValue() as? String)?.hasPrefix("theme_save_error:") == true)
        #expect(surface.theme.background == before.background)
        #expect(try String(contentsOf: blocked, encoding: .utf8) == "sentinel")
    }
}
