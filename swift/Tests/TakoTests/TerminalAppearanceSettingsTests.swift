/*
 * tako — Terminal appearance settings tests
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

@MainActor
@Suite(.serialized)
struct TerminalAppearanceSettingsTests {
    private var themesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/themes")
    }

    @Test func bundledPresetsAreRealDistinctThemeFiles() throws {
        let names = TerminalAppearanceCatalog.themeNames(paths: [themesDirectory.path])
        #expect(names == ["TakoCore", "Tako Forest", "Tako Night", "Tako Ocean", "Tako Slate"])
        var backgrounds = Set<String>()
        for name in names {
            let theme = TerminalTheme.takoDefault.applyingTheme(named: name, searchPaths: [themesDirectory.path])
            #expect(theme.palette.count == 16, "\(name) needs a complete terminal palette")
            let color = try #require(NSColor(cgColor: theme.background))
            backgrounds.insert(Tako.Brand.hexString(for: color))
        }
        #expect(backgrounds.count == names.count)
    }

    @Test func customCatalogListsReadableThemeFilesWithoutUnsafeNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "background = #112233\n".write(to: dir.appendingPathComponent("My Theme"), atomically: true, encoding: .utf8)
        try "background = #445566\n".write(to: dir.appendingPathComponent("bad\nfont-size = 72"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Not a theme"), withIntermediateDirectories: true)
        #expect(TerminalAppearanceCatalog.themeNames(paths: [dir.path]) == ["My Theme"])
    }

    @Test func appearanceSectionsApplyChoicesWithoutLosingOtherConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("config").path
        try "foreground = #ffffff\nfont-size = 13.5\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        let file = KeybindConfigFile(configPath: configPath)
        file.reload()
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: file)

        #expect(dialog.tabLayout.count == 5)
        let last = try #require(dialog.tabLayout.last)
        #expect(last.column + last.label.count < dialog.columns)
        dialog.switchTab(to: .themes)
        dialog.filteredSettingItems = TerminalAppearanceCatalog.themeItems(["Tako Ocean"])
        dialog.selectedSettingIndex = 0
        dialog.toggleOrCycleSelectedSetting()
        #expect(file.getSettingValue(for: dialog.filteredSettingItems[0]) == "Tako Ocean")
        let foreground = try #require(TerminalSettingRegistry.setting(for: "foreground"))
        #expect(file.getSettingValue(for: foreground) == "#ffffff")

        dialog.switchTab(to: .fonts)
        let family = try #require(dialog.filteredSettingItems.dropFirst().first)
        dialog.selectedSettingIndex = 1
        dialog.toggleOrCycleSelectedSetting()
        #expect(file.getSettingValue(for: family) == family.title)
        dialog.selectedSettingIndex = 0
        dialog.toggleOrCycleSelectedSetting()
        #expect(file.getSettingValue(for: family) == nil)

        dialog.switchTab(to: .fontSize)
        let size = try #require(dialog.filteredSettingItems.first)
        #expect(size.id == "font-size")
        dialog.toggleOrCycleSelectedSetting()
        #expect(file.getSettingValue(for: size) == "14.5")
        dialog.toggleOrCycleSelectedSetting(reverse: true)
        #expect(file.getSettingValue(for: size) == "13.5")
        #expect(file.getSettingValue(for: foreground) == "#ffffff")
    }

    @Test func fontFamiliesAreInstalledAndSearchable() throws {
        let families = TerminalAppearanceCatalog.fontFamilies()
        #expect(!families.isEmpty)
        let family = try #require(families.first)
        #expect(NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) != nil)
        let dialog = TerminalSettingsDialog(style: .from(nil), initialTab: .fonts)
        dialog.filterItems(family)
        #expect(dialog.filteredSettingItems.contains { $0.title == family })
    }

    @Test func anUnavailableThemeIsReportedWithoutChangingTheConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config").path
        let original = "theme = Missing-Tako-Theme-91D4\nforeground = #ffffff\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)
        let file = KeybindConfigFile(configPath: path)
        file.reload()
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: file, initialTab: .themes)
        #expect(dialog.themeWarning?.contains("Missing-Tako-Theme-91D4") == true)
        #expect((dialog.accessibilityValue() as? String)?.contains("Themes:") == true)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
    }

    @Test func appearanceSectionsAreReachableWithTheMouse() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: KeybindConfigFile(configPath: path))
        dialog.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        window.contentView = dialog
        for entry in dialog.tabLayout where entry.tab != .keybindings {
            let point = dialog.cell(entry.column + 1, 1)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: dialog.convert(NSPoint(x: point.x, y: point.y + 2), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
            dialog.mouseDown(with: event)
            #expect(dialog.activeTab == entry.tab)
        }
    }

    @Test func appearanceSectionsRenderInTheSettingsDialog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let config = KeybindConfigFile(configPath: dir.appendingPathComponent("config").path)
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: config)
        dialog.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        window.contentView = dialog
        let names = TerminalAppearanceCatalog.themeNames(paths: [themesDirectory.path])
        for tab in [TerminalSettingsDialog.SettingsTab.themes, .fonts, .fontSize] {
            dialog.switchTab(to: tab)
            if tab == .themes {
                dialog.filteredSettingItems = TerminalAppearanceCatalog.themeItems(names)
                for name in names {
                    dialog.themePreviews[name] = TerminalTheme.takoDefault.applyingTheme(named: name, searchPaths: [themesDirectory.path])
                }
            }
            dialog.layoutSubtreeIfNeeded()
            let bitmap = try #require(dialog.bitmapImageRepForCachingDisplay(in: dialog.bounds))
            dialog.cacheDisplay(in: dialog.bounds, to: bitmap)
            #expect(!dialog.filteredSettingItems.isEmpty)
            if let output = ProcessInfo.processInfo.environment["TAKO_APPEARANCE_FRAMES_DIR"],
               let png = bitmap.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("appearance-\(tab.rawValue).png"))
            }
        }
    }
}
