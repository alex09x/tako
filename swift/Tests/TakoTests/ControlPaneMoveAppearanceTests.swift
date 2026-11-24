/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

/// A pane moved into another tab keeps its look: what its old parents
/// (session, workspace) resolved to travels as one layer -- preset and
/// fields together -- into its own record, under its explicit fields. An own
/// preset is left as written; a style that cannot be stored refuses the move.
/// Private stores throughout; effective themes are read back from disk.
@MainActor @Suite(.serialized)
struct ControlPaneMoveAppearanceTests {
    @MainActor struct Tab {
        let controller: TerminalController
        let window: NSWindow
        var panes: [Tako.SurfaceView] { Array(controller.surfaceTree) }
    }

    private func tab(split: Bool) throws -> Tab {
        let (controller, window) = TerminalTestSupport.loaded()
        window.setContentSize(NSSize(width: 1200, height: 700))
        controller.floatingCanvas.reduceMotionProvider = { true }
        if split {
            let a = try #require(controller.focusedSurface)
            _ = try #require(controller.newSplit(at: a, direction: .right))
        }
        return Tab(controller: controller, window: window)
    }

    private func close(_ tabs: Tab...) {
        for tab in tabs {
            tab.window.close()
            TerminalTestSupport.tearDown(tab.controller, tab.window)
        }
    }

    private func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-move-style-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Two full presets with typography, in a private theme directory.
    private func presetStyles(_ dir: URL) throws -> (styles: ScopedAppearanceStore, file: URL, themes: [String]) {
        let themes = dir.appendingPathComponent("themes")
        let presets = ThemePresetStore(directory: themes, searchPaths: [])
        _ = try presets.save(name: "A", config: "background = #a0a0a0\nfont-family = Monaco\nfont-size = 13\n")
        _ = try presets.save(name: "B", config: "background = #b0b0b0\nfont-family = Menlo\nfont-size = 11\n")
        let file = dir.appendingPathComponent("Appearance.json")
        return (ScopedAppearanceStore(fileURL: file, themeSearchPaths: [themes.path]), file, [themes.path])
    }

    private func same(_ a: TerminalTheme, _ b: TerminalTheme) -> Bool {
        a.background == b.background && a.fontFamily == b.fontFamily && a.fontSize == b.fontSize
    }

    @Test func thePaneKeepsWhatItInheritedAndItsOwnPresetAsWritten() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let styles = ScopedAppearanceStore(fileURL: dir.appendingPathComponent("Appearance.json"))
        let main = workspaces.createWorkspace(name: "Main"), legal = workspaces.createWorkspace(name: "Legal")
        let source = try tab(split: true), destination = try tab(split: false), other = try tab(split: false)
        defer { close(source, destination, other) }
        let sourceTab = source.window.stableTabIdentifier
        workspaces.assignTab(tabIdentifier: sourceTab, to: main.id)
        workspaces.assignTab(tabIdentifier: destination.window.stableTabIdentifier, to: main.id)
        workspaces.assignTab(tabIdentifier: other.window.stableTabIdentifier, to: legal.id)
        try styles.setValue("#010101", for: "background", scope: .session(sourceTab))
        try styles.setValue("17", for: "font-size", scope: .session(sourceTab))
        try styles.setValue("#0a0a0a", for: "foreground", scope: .workspace(main.id))
        let inheriting = source.panes[1], owned = source.panes[0]
        try styles.setValue("Anything", for: "theme", scope: .pane(owned.id))
        let anchor = try #require(destination.panes.first), far = try #require(other.panes.first)
        let full = ["background": "#010101", "font-size": "17", "foreground": "#0a0a0a"]

        // Same workspace, other session: the old parents' whole layer travels.
        try destination.controller.movePaneHere(inheriting, beside: anchor, direction: .right, select: false,
                                                appearance: styles, workspaces: workspaces)
        #expect(styles.document.overrides(for: .pane(inheriting.id)) == full)
        // An own preset is left as written.
        try other.controller.movePaneHere(owned, beside: far, direction: .right, select: false,
                                          appearance: styles, workspaces: workspaces)
        #expect(styles.document.overrides(for: .pane(owned.id)) == ["theme": "Anything"])
        // Already carrying everything it shows: a further move writes nothing new.
        try other.controller.movePaneHere(inheriting, beside: far, direction: .down, select: false,
                                          appearance: styles, workspaces: workspaces)
        #expect(styles.document.overrides(for: .pane(inheriting.id)) == full)
        #expect(styles.document.overrides(for: .session(sourceTab))?["background"] == "#010101", "the source record is untouched")
    }

    @Test func aSharedWorkspacesStyleSurvivesADestinationSessionThatOverridesIt() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let file = dir.appendingPathComponent("Appearance.json")
        let styles = ScopedAppearanceStore(fileURL: file)
        let shared = workspaces.createWorkspace(name: "Shared")
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        let destinationTab = destination.window.stableTabIdentifier
        for tab in [source.window.stableTabIdentifier, destinationTab] { workspaces.assignTab(tabIdentifier: tab, to: shared.id) }
        try styles.setValue("#111111", for: "background", scope: .workspace(shared.id))
        try styles.setValue("17", for: "font-size", scope: .workspace(shared.id))
        try styles.setValue("#eeeeee", for: "background", scope: .session(destinationTab))
        try styles.setValue("25", for: "font-size", scope: .session(destinationTab))
        let moving = source.panes[1], anchor = try #require(destination.panes.first)
        let before = styles.effectiveTheme(global: .takoDefault, workspaceID: shared.id,
                                           sessionID: source.window.stableTabIdentifier, paneID: moving.id)

        try destination.controller.movePaneHere(moving, beside: anchor, direction: .right, select: false,
                                                appearance: styles, workspaces: workspaces)
        let reloaded = ScopedAppearanceStore(fileURL: file)
        let after = reloaded.effectiveTheme(global: .takoDefault, workspaceID: shared.id, sessionID: destinationTab, paneID: moving.id)
        #expect(after.background == before.background && after.fontSize == before.fontSize && after.fontSize == 17,
                "the moved pane keeps the shared workspace's look, not the destination session's")
        let neighbour = reloaded.effectiveTheme(global: .takoDefault, workspaceID: shared.id, sessionID: destinationTab, paneID: anchor.id)
        #expect(neighbour.fontSize == 25, "the destination's own pane keeps its session's look")
    }

    /// Source: preset A (13 pt) with 17 pt stated over it. Destination: preset
    /// B with the same 17 pt. Carrying only the differing preset would reset
    /// the size to A's 13.
    @Test func aPresetTravelsWithTheFieldsStatedOverItEvenWhereTheyMatch() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let (styles, file, paths) = try presetStyles(dir)
        let here = workspaces.createWorkspace(name: "Here"), there = workspaces.createWorkspace(name: "There")
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        let sourceTab = source.window.stableTabIdentifier, destinationTab = destination.window.stableTabIdentifier
        workspaces.assignTab(tabIdentifier: sourceTab, to: here.id)
        workspaces.assignTab(tabIdentifier: destinationTab, to: there.id)
        try styles.setValue("A", for: "theme", scope: .workspace(here.id))
        try styles.setValue("17", for: "font-size", scope: .workspace(here.id))
        try styles.setValue("B", for: "theme", scope: .workspace(there.id))
        try styles.setValue("17", for: "font-size", scope: .workspace(there.id))
        let moving = source.panes[1], anchor = try #require(destination.panes.first)
        let before = styles.effectiveTheme(global: .takoDefault, workspaceID: here.id, sessionID: sourceTab,
                                           paneID: moving.id, themeSearchPaths: paths)
        #expect(before.fontSize == 17 && before.fontFamily == "Monaco")

        try destination.controller.movePaneHere(moving, beside: anchor, direction: .right, select: false,
                                                appearance: styles, workspaces: workspaces)
        let reloaded = ScopedAppearanceStore(fileURL: file, themeSearchPaths: paths)
        let after = reloaded.effectiveTheme(global: .takoDefault, workspaceID: there.id, sessionID: destinationTab,
                                            paneID: moving.id, themeSearchPaths: paths)
        #expect(same(after, before), "preset A and its 17 pt, not A's own 13 pt: \(after.fontSize) \(after.fontFamily)")
    }

    /// A shared workspace preset A (13 pt); the destination session states A
    /// again with 25 pt. The preset keys match, yet the pane must not grow.
    @Test func aSharedPresetStillShieldsThePaneFromADestinationSessionsFields() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let (styles, file, paths) = try presetStyles(dir)
        let shared = workspaces.createWorkspace(name: "Shared")
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        let sourceTab = source.window.stableTabIdentifier, destinationTab = destination.window.stableTabIdentifier
        for tab in [sourceTab, destinationTab] { workspaces.assignTab(tabIdentifier: tab, to: shared.id) }
        try styles.setValue("A", for: "theme", scope: .workspace(shared.id))
        try styles.setValue("A", for: "theme", scope: .session(destinationTab))
        try styles.setValue("25", for: "font-size", scope: .session(destinationTab))
        let moving = source.panes[1], anchor = try #require(destination.panes.first)
        let before = styles.effectiveTheme(global: .takoDefault, workspaceID: shared.id, sessionID: sourceTab,
                                           paneID: moving.id, themeSearchPaths: paths)
        #expect(before.fontSize == 13)

        try destination.controller.movePaneHere(moving, beside: anchor, direction: .right, select: false,
                                                appearance: styles, workspaces: workspaces)
        let reloaded = ScopedAppearanceStore(fileURL: file, themeSearchPaths: paths)
        let after = reloaded.effectiveTheme(global: .takoDefault, workspaceID: shared.id, sessionID: destinationTab,
                                            paneID: moving.id, themeSearchPaths: paths)
        #expect(same(after, before), "A's 13 pt, not the destination session's 25: \(after.fontSize)")
        let neighbour = reloaded.effectiveTheme(global: .takoDefault, workspaceID: shared.id, sessionID: destinationTab,
                                                paneID: anchor.id, themeSearchPaths: paths)
        #expect(neighbour.fontSize == 25)
    }

    @Test func aStyleThatCannotBeKeptRefusesTheMoveWithBothTabsUnchanged() throws {
        let dir = temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        let file = dir.appendingPathComponent("Appearance.json")
        let styles = ScopedAppearanceStore(fileURL: file)
        let source = try tab(split: true), destination = try tab(split: false)
        defer { close(source, destination) }
        try styles.setValue("#010101", for: "background", scope: .session(source.window.stableTabIdentifier))
        try "{\"version\": 2, \"sessions\": {}}".write(to: file, atomically: true, encoding: .utf8)  // edited outside Tako
        let moving = source.panes[1], anchor = try #require(destination.panes.first)
        let before = (source.panes.map(\.id), destination.panes.map(\.id))

        #expect(throws: MovePaneError.self) {
            try destination.controller.movePaneHere(moving, beside: anchor, direction: .right, select: false,
                                                    appearance: styles, workspaces: workspaces)
        }
        #expect((source.panes.map(\.id), destination.panes.map(\.id)) == before)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"version\": 2, \"sessions\": {}}")
    }
}
