/*
 * tako — Immediate theme selection and nested appearance controls
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

@MainActor @Suite(.serialized) struct InstantThemeSelectionTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func catalogContainsOnlyPresetsAndOpeningOrSearchingNeverAppliesOne() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("config")
        let original = "theme = Missing\nfont-size = 18\ncommand = /bin/sh\n"
        try original.write(to: path, atomically: true, encoding: .utf8)
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: KeybindConfigFile(configPath: path.path), initialTab: .themes)
        #expect(dialog.availableTabs == [.keybindings, .terminalSettings, .themes])
        #expect(dialog.filteredSettingItems.allSatisfy { $0.id == "theme" })
        dialog.filterItems("Ocean")
        #expect(try String(contentsOf: path, encoding: .utf8) == original)
        dialog.switchTab(to: .fonts)
        #expect(dialog.activeTab == .themes)
        dialog.switchTab(to: .terminalSettings)
        #expect(dialog.filteredSettingItems.allSatisfy { !ThemePresetConfig.isAppearanceKey($0.id) && $0.id != "theme" })
    }

    @Test func singleClickOnPresetNameAppliesFullThemeWithoutEnterOrSave() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ThemePresetStore(directory: root.appendingPathComponent("themes"), searchPaths: [])
        _ = try store.save(name: "Immediate", config: "font-family = Monaco\nfont-size = 19\nbackground = #123456\n")
        let path = root.appendingPathComponent("config")
        try "foreground = #ffffff\ncommand = /bin/sh\n".write(to: path, atomically: true, encoding: .utf8)
        let file = KeybindConfigFile(configPath: path.path)
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: file, initialTab: .themes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        dialog.frame = NSRect(x: 0, y: 0, width: 1000, height: 650); window.contentView = dialog
        dialog.filterItems("Immediate")
        let origin = dialog.cell(5, 5)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: dialog.convert(NSPoint(x: origin.x, y: origin.y + 2), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        dialog.mouseDown(with: event)
        let saved = try String(contentsOf: path, encoding: .utf8)
        #expect(saved.contains("theme = Immediate") && saved.contains("command = /bin/sh"))
        #expect(!saved.contains("foreground = #ffffff"))
        #expect(file.effectiveSettingValue(for: TerminalAppearanceCatalog.sizeItems[0]) == "19")
        #expect(file.effectiveSettingValue(for: TerminalAppearanceCatalog.fontItems([])[0]) == "Monaco")
    }

    @Test func keyboardNavigationAppliesButUnrelatedKeyNavigationDoesNot() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ThemePresetStore(directory: root.appendingPathComponent("themes"), searchPaths: [])
        for name in ["First", "Second"] { _ = try store.save(name: name, config: "font-size = 17\n") }
        let path = root.appendingPathComponent("config")
        try "theme = First\n".write(to: path, atomically: true, encoding: .utf8)
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: KeybindConfigFile(configPath: path.path), initialTab: .themes)
        dialog.filteredSettingItems = TerminalAppearanceCatalog.themeItems(["First", "Second"])
        dialog.selectedSettingIndex = 0
        dialog.moveSelection(1)
        let applied = try String(contentsOf: path, encoding: .utf8)
        #expect(applied.contains("theme = Second"))
        dialog.switchTab(to: .keybindings)
        dialog.moveSelection(-1)
        #expect(try String(contentsOf: path, encoding: .utf8) == applied)
    }

    @Test func inheritThemeClearsWholeLocalAppearanceAndPreservesOtherScopes() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ScopedAppearanceStore(fileURL: root.appendingPathComponent("Appearance.json"))
        let first = UUID(), second = UUID()
        try store.setValue("17", for: "font-size", scope: .workspace(first))
        try store.setValue("#123456", for: "background", scope: .workspace(first))
        try store.setValue("22", for: "font-size", scope: .workspace(second))
        let context = ScopedAppearanceContext(scope: .workspace(first), title: "Workspace", store: store, globalTheme: { .takoDefault })
        let dialog = TerminalSettingsDialog(style: .from(nil), appearance: context)
        #expect(dialog.availableTabs == [.themes])
        #expect(!dialog.isActiveAppearanceChoice(try #require(dialog.filteredSettingItems.first)))
        dialog.scrollTo(0) // An explicit keyboard Home selection inherits immediately.
        #expect(store.document.overrides(for: .workspace(first)) == nil)
        #expect(store.value(for: "font-size", scope: .workspace(second)) == "22")
    }

    @Test func typingPresetNamesNeverRunsLegacyResetOrApplyShortcuts() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("config")
        let original = "theme = Custom\nfont-size = 19\nforeground = #abcdef\ncommand = /bin/sh\n"
        try original.write(to: path, atomically: true, encoding: .utf8)
        let store = ScopedAppearanceStore(fileURL: root.appendingPathComponent("Appearance.json"))
        let scope = AppearanceScope.workspace(UUID())
        try store.setValue("21", for: "font-size", scope: scope)
        let before = store.document
        let context = ScopedAppearanceContext(scope: scope, title: "Workspace", store: store, globalTheme: { .takoDefault })
        let contexts: [ScopedAppearanceContext?] = [nil, context]
        let keys: [(String, UInt16)] = [("d", 2), ("r", 15), (" ", 49)]
        for appearance in contexts {
            for (text, code) in keys {
                let dialog = TerminalSettingsDialog(style: .from(nil), configFile: KeybindConfigFile(configPath: path.path),
                                                    initialTab: .themes, appearance: appearance)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, characters: text,
                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                dialog.keyDown(with: event)
                #expect(dialog.searchField?.stringValue == text)
                #expect(try String(contentsOf: path, encoding: .utf8) == original)
                #expect(store.document == before)
            }
        }
    }

    @Test func nestedEditorChangesPreviewImmediatelyAndCancelRestoresWithoutSaving() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = KeybindConfigFile(configPath: root.appendingPathComponent("config").path)
        let parent = TerminalSettingsDialog(style: .from(nil), configFile: file, initialTab: .themes)
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let before = surface.theme; let core = surface.core
        let model = ThemePresetEditor(store: ThemePresetStore(directory: root.appendingPathComponent("themes"), searchPaths: []),
                                      original: nil, base: before, copyName: "Live")
        model.parent = parent
        model.preview = ThemePresetPreview(owner: parent, targets: [surface])
        let editor = TerminalSettingsDialog(style: .from(nil), configFile: file, initialTab: .themes, editor: model)
        #expect(editor.availableTabs.contains(.fonts) && editor.availableTabs.contains(.fontSize))
        #expect(editor.tabLayout.map(\.tab) == editor.availableTabs, "Keyboard tab navigation follows the visible order")
        #expect(editor.filteredSettingItems.contains { $0.id == "tab-status-color-working" })
        #expect(editor.setSettingValue("#123456", for: try #require(TerminalSettingRegistry.setting(for: "background"))))
        #expect(surface.theme.background == TerminalTheme.parseColor("#123456"))
        #expect(editor.setSettingValue("19", for: TerminalAppearanceCatalog.sizeItems[0]))
        #expect(surface.theme.fontSize == 19 && surface.core === core)
        editor.presetConfigText?.string = "background = #abcdef\nfont-size = 23\n"
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.presetConfigText))
        #expect(surface.theme.background == TerminalTheme.parseColor("#abcdef") && surface.theme.fontSize == 23)
        editor.switchTab(to: .terminalSettings)
        #expect(editor.filteredSettingItems.allSatisfy { ThemePresetConfig.isAppearanceKey($0.id) })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("themes/Live").path))
        editor.withdraw()
        #expect(surface.theme.background == before.background && surface.theme.fontSize == before.fontSize)
        #expect(surface.core === core)
    }
}
