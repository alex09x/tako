/*
 * tako — Scoped appearance UI and runtime tests
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
struct ScopedAppearanceDialogTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func workspaceEditorNeverWritesGlobalConfigAndResetInherits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        let original = "font-size = 18\nforeground = #abcdef\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let file = KeybindConfigFile(configPath: config.path)
        file.reload()
        let store = ScopedAppearanceStore(fileURL: directory.appendingPathComponent("appearance.json"))
        var global = TerminalTheme.takoDefault
        global.fontSize = 18
        let id = UUID()
        let context = ScopedAppearanceContext(scope: .workspace(id), title: "Workspace: Test", store: store,
                                               globalTheme: { global })
        let dialog = TerminalSettingsDialog(style: .from(nil), configFile: file, appearance: context)
        #expect(dialog.activeTab == .themes)
        #expect(dialog.tabLayout.map(\.tab) == [.themes, .fonts, .fontSize])
        #expect(!dialog.filteredSettingItems.contains { $0.id.hasPrefix("tab-status-") })
        dialog.switchTab(to: .keybindings)
        #expect(dialog.activeTab == .themes)

        dialog.switchTab(to: .fontSize)
        let item = try #require(dialog.filteredSettingItems.first)
        #expect(dialog.effectiveSettingValue(for: item) == "18")
        dialog.toggleOrCycleSelectedSetting()
        #expect(store.value(for: "font-size", scope: .workspace(id)) == "19")
        dialog.resetSelectedSetting()
        #expect(store.value(for: "font-size", scope: .workspace(id)) == nil)
        #expect(dialog.effectiveSettingValue(for: item) == "18")
        // The global default 13 is a meaningful explicit local value too.
        #expect(dialog.setSettingValue("13", for: item))
        #expect(store.value(for: "font-size", scope: .workspace(id)) == "13")
        #expect(try String(contentsOf: config, encoding: .utf8) == original)
    }

    @Test func paneEditorFollowsItsCurrentWorkspaceAndCanInheritEachField() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScopedAppearanceStore(fileURL: directory.appendingPathComponent("appearance.json"))
        let first = UUID(), second = UUID(), pane = UUID()
        try store.setValue("17", for: "font-size", scope: .workspace(first))
        try store.setValue("21", for: "font-size", scope: .workspace(second))
        var destination = first
        let context = ScopedAppearanceContext(scope: .pane(pane), title: "Pane", store: store,
            globalTheme: { .takoDefault }, workspaceID: { destination })
        let dialog = TerminalSettingsDialog(style: .from(nil), initialTab: .fontSize, appearance: context)
        let item = try #require(dialog.filteredSettingItems.first)
        #expect(dialog.effectiveSettingValue(for: item) == "17")
        destination = second
        #expect(dialog.effectiveSettingValue(for: item) == "21")
        dialog.toggleOrCycleSelectedSetting()
        destination = first
        #expect(dialog.effectiveSettingValue(for: item) == "22")
        dialog.resetSelectedSetting()
        #expect(dialog.effectiveSettingValue(for: item) == "17")

        dialog.switchTab(to: .fonts)
        let family = try #require(dialog.filteredSettingItems.dropFirst().first)
        dialog.applyAppearanceChoice(family)
        #expect(store.value(for: "font-family", scope: .pane(pane)) == family.title)
        dialog.applyAppearanceChoice(dialog.filteredSettingItems[0])
        #expect(store.value(for: "font-family", scope: .pane(pane)) == nil)
        #expect(dialog.isActiveAppearanceChoice(dialog.filteredSettingItems[0]))
    }

    @Test func liveOverridesPreserveCoreAndContentsAndRecomputeWhenMoved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScopedAppearanceStore(fileURL: directory.appendingPathComponent("appearance.json"))
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let core = surface.core
        surface.core.feed(bytes: Data("appearance-witness".utf8))
        let original = surface.theme
        let first = UUID(), second = UUID()
        var destination = first
        let observation = SurfaceAppearanceObservation(surface: surface, store: store, workspaceID: { destination })
        defer { withExtendedLifetime(observation) {} }
        // Notifications from mutations reach the same runtime path as the UI.
        try store.setValue("#123456", for: "background", scope: .workspace(first))
        #expect(surface.core === core)
        let text = String(String.UnicodeScalarView(surface.core.viewportRow(row: 0).compactMap { UnicodeScalar($0.ch) }))
        #expect(text.contains("appearance-witness"))
        #expect(NSColor(cgColor: surface.theme.background) == NSColor(cgColor: TerminalTheme.parseColor("#123456")!))
        try store.setValue("23", for: "font-size", scope: .pane(surface.id))
        destination = second
        NotificationCenter.default.post(name: .takoTabsDidChange, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(surface.theme.fontSize == 23)
        #expect(surface.theme.background == original.background)
        try store.reset(.pane(surface.id))
        #expect(surface.theme.fontSize == original.fontSize)
        #expect(surface.core === core)
    }

    @Test func closedTargetsRefuseWrites() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("appearance.json")
        let context = ScopedAppearanceContext(scope: .pane(UUID()), title: "Gone",
            store: ScopedAppearanceStore(fileURL: path), globalTheme: { .takoDefault }, isAvailable: { false })
        #expect(!context.setValue("16", for: "font-size"))
        #expect(context.writeError?.contains("closed") == true)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func openingAndSavingScopedColorKeepsExactRGBBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScopedAppearanceStore(fileURL: directory.appendingPathComponent("appearance.json"))
        let scope = AppearanceScope.workspace(UUID())
        let context = ScopedAppearanceContext(scope: scope, title: "Colors", store: store, globalTheme: { .takoDefault })
        let dialog = TerminalSettingsDialog(style: .from(nil), appearance: context)
        let item = try #require(TerminalSettingRegistry.setting(for: "background"))
        for original in ["#1a1b26", "#123456", "#abcdef", "#000000", "#ffffff"] {
            try store.setValue(original, for: "background", scope: scope)
            dialog.beginEditingColor(item)
            #expect(dialog.colorEditField?.stringValue == original)
            dialog.saveEditedColor()
            #expect(store.value(for: "background", scope: scope) == original)
        }
    }

    @Test func inheritancePreviewMatchesResetWhileKeepingExplicitColorsAndAvoidingWrites() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "background = #abcdef\n".write(to: directory.appendingPathComponent("Child"), atomically: true, encoding: .utf8)
        let path = directory.appendingPathComponent("appearance.json")
        let store = ScopedAppearanceStore(fileURL: path, themeSearchPaths: [directory.path])
        let workspace = UUID(), pane = UUID()
        try store.setValue("#123456", for: "background", scope: .workspace(workspace))
        try store.setValue("Menlo", for: "font-family", scope: .workspace(workspace))
        try store.setValue("Child", for: "theme", scope: .pane(pane))
        try store.setValue("#11ff22", for: "foreground", scope: .pane(pane))
        try store.setValue("Monaco", for: "font-family", scope: .pane(pane))
        let context = ScopedAppearanceContext(scope: .pane(pane), title: "Preview", store: store,
            globalTheme: { .takoDefault }, workspaceID: { workspace })
        let before = try Data(contentsOf: path)
        let preview = context.previewInheriting("theme")
        #expect(preview.background == TerminalTheme.parseColor("#123456"))
        #expect(preview.foreground == TerminalTheme.parseColor("#11ff22"))
        #expect(context.previewInheriting("font-family").fontFamily == "Menlo")
        #expect(context.effectiveTheme.background == TerminalTheme.parseColor("#abcdef"))
        #expect(try Data(contentsOf: path) == before)
        #expect(context.setValue(nil, for: "theme"))
        #expect(context.effectiveTheme.background == preview.background)
        #expect(context.effectiveTheme.foreground == preview.foreground)
    }

    @Test func resettingUnavailableThemeClearsItsWarning() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScopedAppearanceStore(fileURL: directory.appendingPathComponent("appearance.json"))
        let scope = AppearanceScope.workspace(UUID())
        try store.setValue("Missing-\(UUID().uuidString)", for: "theme", scope: scope)
        let context = ScopedAppearanceContext(scope: scope, title: "Missing", store: store, globalTheme: { .takoDefault })
        let dialog = TerminalSettingsDialog(style: .from(nil), appearance: context)
        #expect(dialog.themeWarning != nil)
        dialog.resetSelectedSetting()
        #expect(dialog.themeWarning == nil)
        #expect(store.value(for: "theme", scope: scope) == nil)
    }

    @Test func scopedFontSizeCannotSeedAnotherPanesInheritedSize() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScopedAppearanceStore(fileURL: directory.appendingPathComponent("appearance.json"))
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        surface.close()
        let workspace = UUID()
        let observation = SurfaceAppearanceObservation(surface: surface, store: store, workspaceID: { workspace })
        surface.configObserver = observation
        try store.setValue("24", for: "font-size", scope: .pane(surface.id))
        #expect(surface.theme.fontSize == 24)
        #expect(Tako.inheritedFontSize(from: surface) == nil)
        try store.reset(.pane(surface.id))
        surface.changeFontSize(.increase(3))
        #expect(Tako.inheritedFontSize(from: surface) == surface.theme.fontSize, "Ordinary transient zoom still inherits")
        try store.setValue("20", for: "font-size", scope: .workspace(workspace))
        #expect(surface.theme.fontSize == 20)
        #expect(Tako.inheritedFontSize(from: surface) == nil)
    }
}
