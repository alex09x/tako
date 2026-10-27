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

/// An agent opens a subagent as a split (`takoctl split --child-of`): the
/// pane is both a split of the tab and a subagent of its parent. The row's
/// chevron folds it like any other: its two folds were toggled each on its
/// own, both ended up set, and the tree read that as unfolded.
@Suite(.serialized) @MainActor
struct SidebarSubagentSplitCollapseTests {
    private func tabRow(_ scene: WorkspaceSwitchVisualScene) -> SessionSidebarItem? {
        scene.groups.first { $0.name == "Default" }?.items.first { !$0.isChild }
    }

    private func childTitles(_ scene: WorkspaceSwitchVisualScene) -> [String] {
        scene.groups.first { $0.name == "Default" }?.items.filter(\.isChild).map(\.title) ?? []
    }

    @Test(arguments: [true, false])
    func theChevronFoldsASplitOpenedAsASubagent(asSubagent: Bool) throws {
        let scene = WorkspaceSwitchVisualScene()
        let parent = scene.surface("Claude · lead", .working)
        let child = scene.surface("sub-worker", .working)
        defer {
            SubagentHierarchyStore.shared.unregister(paneId: child.id)
            scene.tearDown()
        }
        scene.addTab(parent, split: child, to: scene.main)
        if asSubagent { SubagentHierarchyStore.shared.registerChild(childId: child.id, parentId: parent.id, label: "sub-worker") }
        scene.mountSidebar()
        #expect(childTitles(scene) == ["Claude · lead", "sub-worker"])
        let unfolded = scene.snapshot()

        let row = try #require(tabRow(scene))
        #expect(!row.isCollapsed)
        scene.store.toggleRowCollapsed(row)
        scene.settle()
        #expect(tabRow(scene)?.isCollapsed == true)
        #expect(childTitles(scene).isEmpty, "folded, no pane rows")
        let folded = scene.snapshot()
        scene.export(folded, "fold-\(asSubagent ? "subagent" : "split")")
        #expect(SidebarPixels.differingFraction(unfolded, folded) > 0.01, "the folded sidebar draws fewer rows")

        scene.store.toggleRowCollapsed(try #require(tabRow(scene)))
        scene.settle()
        #expect(tabRow(scene)?.isCollapsed == false)
        #expect(childTitles(scene) == ["Claude · lead", "sub-worker"])
        #expect(SidebarPixels.differingFraction(unfolded, scene.snapshot()) < 0.002, "unfolded again, drawn as before")
    }
    /// A one-pane tab whose agent opened a subagent in another tab: folded,
    /// it keeps its chevron, or it could never be unfolded.
    @Test func aFoldedSubagentGroupKeepsItsChevron() throws {
        let scene = WorkspaceSwitchVisualScene()
        let parent = scene.surface("Claude · lead", .working)
        let kid = scene.surface("sub-worker", .working)
        defer {
            SubagentHierarchyStore.shared.unregister(paneId: kid.id)
            scene.tearDown()
        }
        scene.addTab(parent, to: scene.main)
        scene.addTab(kid, to: scene.main)
        SubagentHierarchyStore.shared.registerChild(childId: kid.id, parentId: parent.id, label: "sub-worker")
        scene.mountSidebar()
        let row = try #require(tabRow(scene))
        #expect(row.title == "Claude · lead")
        #expect(row.hasChildren && !row.isCollapsed)

        scene.store.toggleRowCollapsed(row)
        scene.settle()
        let folded = try #require(tabRow(scene))
        #expect(folded.isCollapsed)
        #expect(folded.hasChildren, "folded, the tab keeps the chevron that unfolds it")

        scene.store.toggleRowCollapsed(folded)
        scene.settle()
        #expect(tabRow(scene)?.isCollapsed == false)
        #expect(tabRow(scene)?.hasChildren == true)
    }
}
