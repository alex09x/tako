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
import SwiftUI
import Testing
@testable import Tako

/// The reference's workspace menu (sidebar.js wsMenu, `.ws .act`): new
/// session here, rename, colour, collapse, appearance and a delete that waits
/// for an empty workspace and never removes the last one.
@Suite(.serialized) @MainActor
struct SidebarWorkspaceActionsTests {
    private func sandbox() throws -> (WorkspaceStore, URL) {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-ws-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        store.resetForTesting()
        return (store, dir)
    }

    private func actions(_ id: UUID, _ store: WorkspaceStore, sessions: Int, collapsed: Bool = false,
                         newSession: @escaping () -> Void = {}, toggle: @escaping () -> Void = {}) -> SidebarWorkspaceActions {
        SidebarWorkspaceActions(workspaceID: id, name: store.workspace(for: id)?.name ?? "", sessionCount: sessions,
                                isCollapsed: collapsed, workspaces: store, window: nil,
                                newSession: newSession, toggleCollapse: toggle)
    }

    private func run(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return }
        _ = (item.target as? NSObject)?.perform(action, with: item)
    }

    @Test func deleteWaitsForAnEmptyWorkspaceAndKeepsTheLastOne() throws {
        let (store, dir) = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = store.createWorkspace(name: "Infra")

        let busy = actions(other.id, store, sessions: 2)
        #expect(!busy.canDelete && busy.deleteTitle == "Delete (move 2 sessions first)")
        #expect(busy.menu().items.first { $0.identifier?.rawValue == "SidebarWorkspaceDelete" }?.isEnabled == false)
        busy.delete()
        #expect(store.workspace(for: other.id) != nil, "a busy workspace was deleted")

        let empty = actions(other.id, store, sessions: 0)
        #expect(empty.canDelete && empty.deleteTitle == "Delete Workspace")
        run(empty.menu().items.first { $0.identifier?.rawValue == "SidebarWorkspaceDelete" })
        #expect(store.workspace(for: other.id) == nil)

        let last = actions(WorkspaceStore.defaultWorkspaceId, store, sessions: 0)
        #expect(!last.canDelete, "the last workspace can be deleted")
    }

    @Test func colourRenameAndCollapseReachTheStore() throws {
        let (store, dir) = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = store.createWorkspace(name: "Frontend")
        var toggled = 0, created = 0
        let a = actions(ws.id, store, sessions: 1, newSession: { created += 1 }, toggle: { toggled += 1 })

        let colors = a.colorMenu()
        #expect(colors.items.map { $0.identifier?.rawValue } == SidebarWorkspaceActions.colors.map { "SidebarWorkspaceColor-\($0.key)" })
        run(colors.items.first { $0.identifier?.rawValue == "SidebarWorkspaceColor-purple" })
        #expect(store.workspace(for: ws.id)?.color == "purple")
        #expect(actions(ws.id, store, sessions: 1).colorMenu().items.first { $0.state == .on }?.identifier?.rawValue
                == "SidebarWorkspaceColor-purple")
        run(colors.items.first { $0.identifier?.rawValue == "SidebarWorkspaceColor-teal" })
        #expect(store.workspace(for: ws.id)?.color == nil, "teal is the default, stored as none")

        SidebarWorkspaceActions.rename(ws.id, to: "Web", in: store)
        #expect(store.workspace(for: ws.id)?.name == "Web")
        SidebarWorkspaceActions.rename(ws.id, to: "", in: store)
        #expect(store.workspace(for: ws.id)?.name == "Web", "an empty name replaced the old one")

        let menu = a.menu()
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title).prefix(4)
                == ["New Session Here", "Rename", "Color", "Minimize"])
        run(menu.items.first { $0.identifier?.rawValue == "SidebarWorkspaceNewSession" })
        run(menu.items.first { $0.identifier?.rawValue == "SidebarWorkspaceCollapse" })
        #expect(created == 1 && toggled == 1)
        #expect(actions(ws.id, store, sessions: 1, collapsed: true).collapseTitle == "Expand")
    }

    @Test func theHeaderCarriesPlusMoreAndTheColourDot() throws {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        scene.populate()
        scene.settle()
        let content = try #require(scene.sidebarWindow.contentView)
        let key = scene.main.id.uuidString.lowercased()
        func find(_ id: String, in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            for sub in view.subviews { if let hit = find(id, in: sub) { return hit } }
            return nil
        }
        for id in ["SidebarWorkspaceAdd-\(key)", "SidebarWorkspaceMore-\(key)", "SidebarWorkspaceColorDot-\(key)"] {
            #expect(find(id, in: content) != nil, "\(id) is missing")
        }
    }
}
