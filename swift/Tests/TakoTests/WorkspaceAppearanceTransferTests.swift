/*
 * tako — Session styles survive workspace moves
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@MainActor @Suite(.serialized) struct WorkspaceAppearanceTransferTests {
    @Test func inheritedPresetTravelsWithTheSessionAndExplicitSplitStyleWins() throws {
        let scene = WorkspaceSwitchVisualScene(); defer { scene.tearDown() }
        let themes = scene.dir.appendingPathComponent("themes")
        let presets = ThemePresetStore(directory: themes, searchPaths: [])
        _ = try presets.save(name: "Source", config: "background = #123456\nfont-family = Monaco\nfont-size = 19\npalette = 1=#f01234\n")
        _ = try presets.save(name: "Own", config: "background = #abcdef\nfont-size = 23\n")
        _ = try presets.save(name: "Destination", config: "background = #332211\nfont-size = 11\n")
        let styles = ScopedAppearanceStore(fileURL: scene.dir.appendingPathComponent("Appearance.json"), themeSearchPaths: [themes.path])
        try styles.applyPreset("Source", scope: .workspace(scene.main.id))
        try styles.setValue("#ff3355", for: "foreground", scope: .workspace(scene.main.id))
        try styles.applyPreset("Destination", scope: .workspace(scene.legal.id))
        let first = scene.surface("inherited", .idle), own = scene.surface("own", .idle)
        let tab = scene.addTab(first, split: own, to: scene.main)
        let tabID = tab.window.stableTabIdentifier
        try styles.applyPreset("Own", scope: .pane(own.id))
        try styles.setValue("#010203", for: "foreground", scope: .pane(own.id))
        first.configObserver = SurfaceAppearanceObservation(surface: first, store: styles,
            workspaceID: { scene.workspaces.workspace(forTab: tabID)?.id })
        own.configObserver = SurfaceAppearanceObservation(surface: own, store: styles,
            workspaceID: { scene.workspaces.workspace(forTab: tabID)?.id })
        NotificationCenter.default.post(name: .takoTabsDidChange, object: nil)
        let core = first.core, identity = first.id, pty = first.pty
        #expect(first.theme.fontSize == 19)
        #expect(scene.store.moveTab(tabID, to: scene.legal.id, around: scene.anchor,
            workspaceStore: scene.workspaces, appearanceStore: styles))
        #expect(styles.value(for: "theme", scope: .pane(first.id)) == "Source")
        #expect(first.theme.background == TerminalTheme.parseColor("#123456") && first.theme.fontSize == 19)
        #expect(first.theme.palette[1] == TerminalTheme.parseColor("#f01234"))
        #expect(own.theme.background == TerminalTheme.parseColor("#abcdef") && own.theme.fontSize == 23)
        #expect(styles.document.overrides(for: .pane(own.id)) == ["theme": "Own", "foreground": "#010203"])
        #expect(first.id == identity && first.core === core && first.pty === pty)
        let loaded = ScopedAppearanceStore(fileURL: styles.fileURL, themeSearchPaths: [themes.path])
        #expect(loaded.effectiveTheme(global: .takoDefault, workspaceID: scene.legal.id, paneID: identity).fontSize == 19)
        try styles.reset(.pane(identity))
        #expect(first.theme.fontSize == 11, "Explicit Inherit adopts the destination after the move")
    }

    @Test func localFieldsOverrideInheritedCustomFieldsWithoutPartialSplitWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScopedAppearanceStore(fileURL: root.appendingPathComponent("Appearance.json"))
        let source = UUID(), first = UUID(), second = UUID()
        try store.setValue("#123456", for: "background", scope: .workspace(source))
        try store.setValue("18", for: "font-size", scope: .workspace(source))
        try store.setValue("21", for: "font-size", scope: .pane(first))
        let changed = try store.preserveWorkspaceStyle(from: source, for: [first, second])
        #expect(changed == Set([first, second]))
        #expect(store.value(for: "font-size", scope: .pane(first)) == "21")
        #expect(store.value(for: "font-size", scope: .pane(second)) == "18")
        #expect(store.value(for: "background", scope: .pane(first)) == "#123456")
    }

    @Test func unstyledSessionsStillInheritTheirDestination() throws {
        let scene = WorkspaceSwitchVisualScene(); defer { scene.tearDown() }
        let styles = ScopedAppearanceStore(fileURL: scene.dir.appendingPathComponent("Appearance.json"))
        try styles.setValue("#abcdef", for: "background", scope: .workspace(scene.legal.id))
        let surface = scene.surface("unstyled", .idle)
        let tab = scene.addTab(surface, to: scene.main)
        #expect(scene.store.moveTab(tab.window.stableTabIdentifier, to: scene.legal.id, around: scene.anchor,
            workspaceStore: scene.workspaces, appearanceStore: styles))
        #expect(styles.document.overrides(for: .pane(surface.id)) == nil)
        #expect(styles.effectiveTheme(global: .takoDefault, workspaceID: scene.legal.id, paneID: surface.id).background == TerminalTheme.parseColor("#abcdef"))
    }

    @Test func aFailedStyleWriteRefusesTheMoveAndLeavesTheSessionIntact() throws {
        let scene = WorkspaceSwitchVisualScene(); defer { scene.tearDown() }
        let directory = scene.dir.appendingPathComponent("styles")
        let styles = ScopedAppearanceStore(fileURL: directory.appendingPathComponent("Appearance.json"))
        try styles.setValue("#123456", for: "background", scope: .workspace(scene.main.id))
        let tab = scene.addTab(scene.surface("protected", .idle), to: scene.main)
        let before = styles.document, bytes = try Data(contentsOf: styles.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(!scene.store.moveTab(tab.window.stableTabIdentifier, to: scene.legal.id, around: scene.anchor,
            workspaceStore: scene.workspaces, appearanceStore: styles))
        #expect(scene.workspaces.workspace(forTab: tab.window.stableTabIdentifier)?.id == scene.main.id)
        let after = try Data(contentsOf: styles.fileURL)
        #expect(styles.document == before && after == bytes)
    }
}
