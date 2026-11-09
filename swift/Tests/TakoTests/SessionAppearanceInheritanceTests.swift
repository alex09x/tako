/*
 * tako — Global -> workspace -> session -> pane appearance inheritance
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

@MainActor @Suite(.serialized) struct SessionAppearanceInheritanceTests {
    private func color(_ hex: String) -> CGColor? { TerminalTheme.parseColor(hex) }

    private func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-session-style-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Store backed by themes in a private directory: "Ocean" and "Paper" are
    /// legacy color themes (no preset header, so parent fonts survive them);
    /// "Big" is a full versioned preset, which also defines typography.
    private func presetStore(_ dir: URL) throws -> ScopedAppearanceStore {
        let themes = dir.appendingPathComponent("themes")
        let presets = ThemePresetStore(directory: themes, searchPaths: [])
        _ = try presets.save(name: "Big", config: "background = #202020\nfont-size = 30\n")
        try "background = #101010\nforeground = #a0a0a0\n".write(to: themes.appendingPathComponent("Ocean"), atomically: true, encoding: .utf8)
        try "background = #fafafa\nforeground = #00bb00\n".write(to: themes.appendingPathComponent("Paper"), atomically: true, encoding: .utf8)
        return ScopedAppearanceStore(fileURL: dir.appendingPathComponent("Appearance.json"), themeSearchPaths: [themes.path])
    }

    @Test func legacyVersionOneMigratesWithoutRewritingAndUnknownVersionsFailClosed() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let ws = UUID(), pane = UUID(), url = dir.appendingPathComponent("Appearance.json")
        let legacy = "{\"version\": 1, \"workspaces\": {\"\(ws.uuidString.lowercased())\": {\"background\": \"#123456\"}}, \"panes\": {\"\(pane.uuidString)\": {\"font-size\": \"17\"}}}"
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let store = ScopedAppearanceStore(fileURL: url)
        #expect(store.loadError == nil)
        #expect(store.document.version == AppearanceDocument.currentVersion)
        #expect(store.document.sessions.isEmpty)
        let theme = store.effectiveTheme(global: .takoDefault, workspaceID: ws, sessionID: "tab", paneID: pane)
        #expect(theme.background == color("#123456") && theme.fontSize == 17)
        #expect(try String(contentsOf: url, encoding: .utf8) == legacy, "Loading alone never rewrites a legacy file")

        try store.setValue("#654321", for: "foreground", scope: .session("tab"))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(written?["version"] as? Int == 2)
        #expect((written?["sessions"] as? [String: [String: String]])?["tab"]?["foreground"] == "#654321")
        let reloaded = ScopedAppearanceStore(fileURL: url)
        #expect(reloaded.document == store.document)

        for (name, text) in [("future", "{\"version\": 3, \"sessions\": {}}"),
                             ("mixed", "{\"version\": 1, \"sessions\": {\"tab\": {\"background\": \"#111111\"}}}"),
                             ("bad-session", "{\"version\": 2, \"sessions\": {\"\": {\"background\": \"#111111\"}}}")] {
            let file = dir.appendingPathComponent("\(name).json")
            try text.write(to: file, atomically: true, encoding: .utf8)
            let guarded = ScopedAppearanceStore(fileURL: file)
            #expect(guarded.loadError != nil, "\(name) must fail closed")
            #expect(throws: AppearanceStoreError.self) { try guarded.setValue("#222222", for: "background", scope: .session("tab")) }
            #expect(try String(contentsOf: file, encoding: .utf8) == text)
        }
    }

    @Test func eachScopeAppliesItsFullPresetThenItsOwnFields() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try presetStore(dir)
        let ws = UUID(), pane = UUID(), session = "SESSION-A"
        try store.setValue("Ocean", for: "theme", scope: .workspace(ws))
        try store.setValue("#aa0000", for: "foreground", scope: .workspace(ws))
        try store.setValue("20", for: "font-size", scope: .workspace(ws))
        var theme = store.effectiveTheme(global: .takoDefault, workspaceID: ws, sessionID: session, paneID: pane)
        #expect(theme.background == color("#101010") && theme.foreground == color("#aa0000") && theme.fontSize == 20)

        // A session preset replaces the parent's explicit colors; the parent's
        // font survives a colors-only preset.
        try store.setValue("Paper", for: "theme", scope: .session(session))
        theme = store.effectiveTheme(global: .takoDefault, workspaceID: ws, sessionID: session, paneID: pane)
        #expect(theme.background == color("#fafafa") && theme.foreground == color("#00bb00") && theme.fontSize == 20)

        // The session's explicit field beats its own preset.
        try store.setValue("#333333", for: "background", scope: .session(session))
        theme = store.effectiveTheme(global: .takoDefault, workspaceID: ws, sessionID: session, paneID: pane)
        #expect(theme.background == color("#333333"))

        // A pane preset with typography beats both parents; its own field wins last.
        try store.setValue("Big", for: "theme", scope: .pane(pane))
        theme = store.effectiveTheme(global: .takoDefault, workspaceID: ws, sessionID: session, paneID: pane)
        #expect(theme.background == color("#202020") && theme.fontSize == 30)
        try store.setValue("#444444", for: "background", scope: .pane(pane))
        theme = store.effectiveTheme(global: .takoDefault, workspaceID: ws, sessionID: session, paneID: pane)
        #expect(theme.background == color("#444444"))

        // The existing two-level API keeps its exact meaning (no session layer).
        let legacy = store.effectiveTheme(global: .takoDefault, workspaceID: ws, paneID: nil)
        #expect(legacy.background == color("#101010") && legacy.foreground == color("#aa0000"))
    }

    @Test func parentChangesFlowThroughExceptWhereTheChildOverrides() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ScopedAppearanceStore(fileURL: dir.appendingPathComponent("Appearance.json"))
        let ws = UUID(), session = "S"
        try store.setValue("#111111", for: "background", scope: .workspace(ws))
        try store.setValue("#222222", for: "background", scope: .session(session))
        try store.setValue("15", for: "font-size", scope: .workspace(ws))
        try store.setValue("#999999", for: "background", scope: .workspace(ws))
        try store.setValue("18", for: "font-size", scope: .workspace(ws))
        let theme = store.effectiveTheme(global: .takoDefault, workspaceID: ws, sessionID: session, paneID: UUID())
        #expect(theme.background == color("#222222"), "Child override survives a parent change")
        #expect(theme.fontSize == 18, "Unset fields follow the parent")
        let elsewhere = store.effectiveTheme(global: .takoDefault, workspaceID: ws, sessionID: "other", paneID: nil)
        #expect(elsewhere.background == color("#999999"))
    }

    @Test func resettingASessionRemovesItsRecordAndContextsInheritThroughIt() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ScopedAppearanceStore(fileURL: dir.appendingPathComponent("Appearance.json"))
        let ws = UUID(), pane = UUID(), session = "S"
        try store.setValue("#111111", for: "background", scope: .workspace(ws))
        try store.setValue("#222222", for: "background", scope: .session(session))
        try store.setValue("#00ff00", for: "foreground", scope: .session(session))
        let sessionContext = ScopedAppearanceContext(scope: .session(session), title: "Session", store: store,
            globalTheme: { .takoDefault }, workspaceID: { ws })
        let paneContext = ScopedAppearanceContext(scope: .pane(pane), title: "Pane", store: store,
            globalTheme: { .takoDefault }, workspaceID: { ws }, sessionID: { session })
        #expect(sessionContext.effectiveTheme.background == color("#222222"))
        #expect(sessionContext.inheritedTheme.background == color("#111111"))
        #expect(sessionContext.previewInheriting("background").background == color("#111111"))
        #expect(paneContext.inheritedTheme.background == color("#222222"))
        #expect(paneContext.effectiveTheme.foreground == color("#00ff00"))

        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: .takoScopedAppearanceDidChange, object: store, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.reset(.session(session))
        #expect(notified == 1)
        #expect(store.document.sessions.isEmpty)
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect((disk?["sessions"] as? [String: Any])?.isEmpty == true)
        #expect(paneContext.effectiveTheme.background == color("#111111"))
        #expect(paneContext.effectiveTheme.foreground == TerminalTheme.takoDefault.foreground)
    }

    @Test func everyPaneOfASessionSharesTheStableTabIdentityIncludingNewSplits() throws {
        let scene = WorkspaceSwitchVisualScene(); defer { scene.tearDown() }
        let styles = ScopedAppearanceStore(fileURL: scene.dir.appendingPathComponent("Appearance.json"))
        let first = scene.surface("Claude · brief", .idle), second = scene.surface("zsh", .idle)
        let tab = scene.addTab(first, split: second, to: scene.main)
        let tabID = tab.window.stableTabIdentifier
        #expect(first.appearanceSessionID == tabID && second.appearanceSessionID == tabID)
        for surface in [first, second] {
            surface.configObserver = SurfaceAppearanceObservation(surface: surface, store: styles,
                workspaceID: { scene.workspaces.workspace(forTab: tabID)?.id })
        }
        try styles.setValue("#123123", for: "background", scope: .session(tabID.lowercased()))
        #expect(styles.value(for: "background", scope: .session(tabID)) == "#123123", "Identity is case-normalized")
        #expect(first.theme.background == color("#123123") && second.theme.background == color("#123123"))

        first.title = "renamed"
        let core = first.core, pty = first.pty
        let late = scene.surface("late split", .idle)
        tab.window.contentView?.addSubview(late)
        #expect(late.appearanceSessionID == tabID, "A pane added later joins the same session")
        late.configObserver = SurfaceAppearanceObservation(surface: late, store: styles,
            workspaceID: { scene.workspaces.workspace(forTab: tabID)?.id })
        NotificationCenter.default.post(name: .takoTabsDidChange, object: nil)
        #expect(late.theme.background == color("#123123"))
        #expect(first.core === core && first.pty === pty)
        #expect(styles.document.panes.isEmpty, "Session styling never writes per-pane records")
    }

    @Test func presetReferencesIncludeSessionsForRenameAndDelete() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        let session = UUID().uuidString
        try scene.styles.setValue("Mine", for: "theme", scope: .session(session))
        #expect(scene.styles.references(toPreset: "mine").contains(.session(session)))
        do {
            _ = try scene.call("delete", ["name": .string("Mine")])
            Issue.record("a preset assigned to a session was deleted")
        } catch let error as ControlError {
            #expect(error.code == .busy)
            #expect(error.candidates.contains("session:\(session.lowercased())"))
        }
        try scene.call("rename", ["name": .string("Mine"), "new_name": .string("Renamed")])
        #expect(scene.styles.value(for: "theme", scope: .session(session)) == "Renamed")
        #expect(scene.styles.references(toPreset: "Mine").isEmpty)
        try scene.styles.reset(.session(session))
        _ = try scene.call("delete", ["name": .string("Renamed")])
    }

    @Test func movingASessionCarriesTheSourceStyleIntoTheSessionRecord() throws {
        let scene = WorkspaceSwitchVisualScene(); defer { scene.tearDown() }
        let styles = try presetStore(scene.dir)
        try styles.setValue("#abcabc", for: "background", scope: .workspace(scene.main.id))
        try styles.setValue("19", for: "font-size", scope: .workspace(scene.main.id))
        try styles.setValue("#00aa00", for: "background", scope: .workspace(scene.legal.id))
        let surface = scene.surface("moved", .idle), pinned = scene.surface("pinned", .idle)
        let tab = scene.addTab(surface, split: pinned, to: scene.main)
        let tabID = tab.window.stableTabIdentifier
        try styles.setValue("#ff0000", for: "foreground", scope: .session(tabID))
        try styles.setValue("#0000ff", for: "background", scope: .pane(pinned.id))
        let before = styles.effectiveTheme(global: .takoDefault, workspaceID: scene.main.id, sessionID: tabID, paneID: surface.id)

        #expect(scene.store.moveTab(tabID, to: scene.legal.id, around: scene.anchor,
            workspaceStore: scene.workspaces, appearanceStore: styles))
        #expect(scene.workspaces.workspace(forTab: tabID)?.id == scene.legal.id)
        #expect(styles.document.overrides(for: .session(tabID)) == ["background": "#abcabc", "font-size": "19", "foreground": "#ff0000"])
        #expect(styles.document.overrides(for: .pane(pinned.id)) == ["background": "#0000ff"])
        #expect(styles.document.overrides(for: .pane(surface.id)) == nil)
        #expect(styles.document.overrides(for: .workspace(scene.main.id))?["background"] == "#abcabc", "Source keeps its own style")
        let after = styles.effectiveTheme(global: .takoDefault, workspaceID: scene.legal.id, sessionID: tabID, paneID: surface.id)
        #expect(after.background == before.background && after.fontSize == before.fontSize && after.foreground == before.foreground)
        #expect(styles.effectiveTheme(global: .takoDefault, workspaceID: scene.legal.id, sessionID: tabID,
                                      paneID: UUID()).background == color("#abcabc"), "A later split keeps the carried style")

        // A session with its own colors-only preset gains only the source fonts.
        let owned = scene.addTab(scene.surface("owned", .idle), to: scene.main)
        let ownedID = owned.window.stableTabIdentifier
        try styles.setValue("Paper", for: "theme", scope: .session(ownedID))
        #expect(scene.store.moveTab(ownedID, to: scene.legal.id, around: scene.anchor,
            workspaceStore: scene.workspaces, appearanceStore: styles))
        #expect(styles.document.overrides(for: .session(ownedID)) == ["theme": "Paper", "font-size": "19"])
    }
}
