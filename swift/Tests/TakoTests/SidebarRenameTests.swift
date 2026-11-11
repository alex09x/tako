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
import Foundation
import Testing
@testable import Tako

/// Renaming in place in the sidebar, on a real session window and terminal:
/// a session's name is its tab's title override, a terminal's its own pane
/// name; Return keeps, Esc leaves, empty and «Use Automatic Name» give the
/// automatic name back; a failed save keeps the draft and says why; the edit
/// belongs to the sidebar it was started in and survives its row moving.
@Suite(.serialized) @MainActor
struct SidebarRenameTests {
    let store = SessionSidebarStore.shared
    let editor = SidebarRenameEditor.shared

    private func session() -> (Tako.SurfaceView, NSWindow, BaseTerminalController) {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let controller = BaseTerminalController(Tako.App(), surfaceTree: .init(view: view))
        controller.window = window
        window.windowController = controller
        return (view, window, controller)
    }

    private func rows(_ view: Tako.SurfaceView, _ window: NSWindow) -> (session: SessionSidebarItem, pane: SessionSidebarItem) {
        let tab = window.stableTabIdentifier
        return (SessionSidebarItem(id: tab, surfaceId: view.id, index: 0, isSelected: true, title: "fish", tabId: tab),
                SessionSidebarItem(id: "\(tab)-pane-\(view.id)", surfaceId: view.id, index: 0, isSelected: false, title: "fish",
                                   isChild: true, indentationLevel: 2, tabId: tab))
    }

    private func settle(_ seconds: TimeInterval = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    @Test func aSessionIsRenamedThroughItsTitleOverride() {
        let (view, window, controller) = session()
        defer { window.close(); editor.cancel() }
        let (row, pane) = rows(view, window)
        #expect(store.canRename(row, around: window))

        editor.begin(row, in: window, store: store)
        editor.draft.text = "  deploy  "
        editor.cancel()
        #expect(controller.titleOverride == nil, "Esc leaves the name as it was")

        editor.begin(row, in: window, store: store)
        editor.draft.text = "  deploy  "
        #expect(editor.commit(row, in: window, store: store))
        #expect(controller.titleOverride == "deploy" && editor.edit == nil)
        #expect(store.ownName(of: pane, around: window) == nil, "the terminal's own name is separate")

        editor.begin(row, in: window, store: store)
        #expect(editor.draft.text == "deploy", "the field starts from the name someone gave")
        editor.draft.text = "   "
        #expect(editor.commit(row, in: window, store: store))
        #expect(controller.titleOverride == nil, "an empty name is the automatic one")
        controller.titleOverride = "x"
        editor.useAutomaticName(row, in: window, store: store)
        #expect(controller.titleOverride == nil)
    }

    @Test func aTerminalIsRenamedThroughItsPaneName() {
        let (view, window, controller) = session()
        defer { window.close(); editor.cancel(); PaneTitleStore.shared.setTitle(nil, for: view.id) }
        let (row, pane) = rows(view, window)
        editor.begin(pane, in: window, store: store)
        editor.draft.text = " build logs "
        #expect(editor.commit(pane, in: window, store: store))
        #expect(PaneTitleStore.shared.title(for: view.id) == "build logs", "the card header shows the same name")
        #expect(controller.titleOverride == nil && store.ownName(of: row, around: window) == nil)
        editor.useAutomaticName(pane, in: window, store: store)
        #expect(PaneTitleStore.shared.title(for: view.id) == nil)
    }

    @Test func aNameThatCannotBeSavedKeepsTheDraftAndSaysWhy() throws {
        let (view, window, _) = session()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("PaneTitles.json")
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        editor.paneTitles = PaneTitleStore(fileURL: file)
        defer { window.close(); editor.cancel(); editor.paneTitles = .shared; try? FileManager.default.removeItem(at: dir) }
        let (_, pane) = rows(view, window)

        editor.begin(pane, in: window, store: store)
        editor.draft.text = "build logs"
        #expect(!editor.commit(pane, in: window, store: store))
        #expect(editor.isEditing(pane.id, in: window), "the edit stays open")
        #expect(editor.draft.text == "build logs", "with what was typed")
        #expect(editor.draft.error != nil, "and why it was not kept")
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json", "nothing was written")
        // Return again once it can be saved: the same draft is kept.
        editor.paneTitles = .shared
        #expect(editor.commit(pane, in: window, store: store))
        #expect(PaneTitleStore.shared.title(for: view.id) == "build logs")
        PaneTitleStore.shared.setTitle(nil, for: view.id)
    }

    @Test func anEditBelongsToItsSidebarAndSurvivesItsRowMoving() {
        let (view, window, _) = session()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close(); editor.cancel(); PaneTitleStore.shared.setTitle(nil, for: view.id) }
        let (_, pane) = rows(view, window)

        editor.begin(pane, in: window, store: store)
        #expect(editor.isEditing(pane.id, in: window))
        #expect(!editor.isEditing(pane.id, in: other), "another window keeps showing the name")

        // The row changes status group mid-typing: a new field, the same draft;
        // the old field going away does not end the edit.
        let first = editor.mounted()
        editor.draft.text = "agent run"
        _ = editor.mounted()
        editor.blurred(mount: first)
        settle()
        #expect(editor.isEditing(pane.id, in: window) && editor.draft.text == "agent run")
        #expect(editor.commit(pane, in: window, store: store))
        #expect(PaneTitleStore.shared.title(for: view.id) == "agent run")

        // Clicking away from the field that shows the edit ends it.
        editor.begin(pane, in: window, store: store)
        let current = editor.mounted()
        editor.blurred(mount: current)
        settle()
        #expect(editor.edit == nil)
    }

    @Test func anAgentRowWithNoTerminalOfItsOwnIsNotOffered() {
        let (view, window, _) = session()
        defer { window.close(); editor.cancel() }
        let tab = window.stableTabIdentifier
        let agent = SessionSidebarItem(id: "\(tab)-agent", surfaceId: UUID(), index: 0, isSelected: false, title: "subagent",
                                       isChild: true, indentationLevel: 2, tabId: tab)
        #expect(!store.canRename(agent, around: window))
        editor.begin(agent, in: window, store: store)
        #expect(editor.edit == nil, "double-click, F2 and the menu all ask canRename")
        #expect(store.setName("x", of: agent, around: window) != nil, "and nothing is written for it")
        #expect(store.canRename(rows(view, window).pane, around: window))
    }
}
