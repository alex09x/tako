/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@Suite @MainActor struct SubagentHierarchyTests {

    @Test func testRegisterAndUnregisterChildren() {
        let store = SubagentHierarchyStore()
        let parentId = UUID()
        let child1 = UUID()
        let child2 = UUID()

        #expect(store.children(of: parentId).isEmpty)
        #expect(!store.hasChildren(parentId))
        #expect(store.parent(of: child1) == nil)

        // Register child 1 with a label
        store.registerChild(childId: child1, parentId: parentId, label: "worker-1")
        #expect(store.hasChildren(parentId))
        #expect(store.children(of: parentId) == [child1])
        #expect(store.parent(of: child1) == parentId)
        #expect(store.label(for: child1) == "worker-1")

        // Register child 2 without a label
        store.registerChild(childId: child2, parentId: parentId)
        #expect(store.children(of: parentId) == [child1, child2])
        #expect(store.parent(of: child2) == parentId)
        #expect(store.label(for: child2) == nil)

        // Update label on child 2
        store.setLabel(for: child2, label: "worker-2")
        #expect(store.label(for: child2) == "worker-2")

        // Unregister child 1
        store.unregister(paneId: child1)
        #expect(store.children(of: parentId) == [child2])
        #expect(store.parent(of: child1) == nil)
        #expect(store.label(for: child1) == nil)

        // Unregister parent: should dissociate remaining children
        store.unregister(paneId: parentId)
        #expect(store.children(of: parentId).isEmpty)
        #expect(!store.hasChildren(parentId))
        #expect(store.parent(of: child2) == nil)
    }

    @Test func testReregisterChildWithNewParent() {
        let store = SubagentHierarchyStore()
        let parent1 = UUID()
        let parent2 = UUID()
        let child = UUID()

        store.registerChild(childId: child, parentId: parent1, label: "sub")
        #expect(store.children(of: parent1) == [child])
        #expect(store.parent(of: child) == parent1)

        // Re-register under parent 2
        store.registerChild(childId: child, parentId: parent2, label: "sub-relocated")
        #expect(store.children(of: parent1).isEmpty)
        #expect(store.children(of: parent2) == [child])
        #expect(store.parent(of: child) == parent2)
        #expect(store.label(for: child) == "sub-relocated")
    }

    @Test func testCollapseAndExpand() {
        let store = SubagentHierarchyStore()
        let parentId = UUID()
        let childId = UUID()

        store.registerChild(childId: childId, parentId: parentId)
        #expect(!store.isCollapsed(parentId))

        store.setCollapsed(parentId, collapsed: true)
        #expect(store.isCollapsed(parentId))

        store.toggleCollapsed(parentId)
        #expect(!store.isCollapsed(parentId))

        store.toggleCollapsed(parentId)
        #expect(store.isCollapsed(parentId))

        // Unregister parent should clean up collapse state
        store.unregister(paneId: parentId)
        #expect(!store.isCollapsed(parentId))
    }

    @Test func testStatusSummarization() {
        let store = SubagentHierarchyStore()
        let parentId = UUID()
        let c1 = UUID()
        let c2 = UUID()
        let c3 = UUID()

        store.registerChild(childId: c1, parentId: parentId)
        store.registerChild(childId: c2, parentId: parentId)
        store.registerChild(childId: c3, parentId: parentId)

        // 1. All same status: 3 running
        let summary1 = store.statusSummary(
            for: parentId,
            statuses: [c1: .running, c2: .running, c3: .running]
        )
        #expect(summary1 == "3 subagents running")

        // 2. Single child: 1 working
        let summarySingle = store.statusSummary(
            for: parentId,
            statuses: [c1: .working]
        )
        #expect(summarySingle == "1 subagent working")

        // 3. Mixed: 2 working, 1 done
        let summary2 = store.statusSummary(
            for: parentId,
            statuses: [c1: .working, c2: .working, c3: .done]
        )
        #expect(summary2 == "2 working, 1 done")

        // 4. Mixed with errors and approval: ordered by priority
        let summary3 = store.statusSummary(
            for: parentId,
            statuses: [c1: .error, c2: .needsApproval, c3: .working]
        )
        #expect(summary3 == "1 error, 1 need approval, 1 working")

        // 5. No child statuses available
        let summaryEmpty = store.statusSummary(for: parentId, statuses: [:])
        #expect(summaryEmpty == nil)
    }

    @Test func testNotificationPosting() {
        let store = SubagentHierarchyStore()
        let parentId = UUID()
        let childId = UUID()

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .takoSubagentHierarchyDidChange,
            object: store,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        store.registerChild(childId: childId, parentId: parentId, label: "agent")
        #expect(notificationCount == 1)

        store.setLabel(for: childId, label: "agent-updated")
        #expect(notificationCount == 2)

        store.setCollapsed(parentId, collapsed: true)
        #expect(notificationCount == 3)

        store.unregister(paneId: childId)
        #expect(notificationCount == 4)
    }

    @Test func testRecursiveDescendants() {
        let store = SubagentHierarchyStore()
        let root = UUID()
        let c1 = UUID()
        let c2 = UUID()
        let grandChild = UUID()

        store.registerChild(childId: c1, parentId: root, label: "child-1")
        store.registerChild(childId: c2, parentId: root, label: "child-2")
        store.registerChild(childId: grandChild, parentId: c1, label: "grandchild")

        #expect(store.children(of: root).count == 2)
        #expect(store.children(of: c1) == [grandChild])

        let desc = store.descendants(of: root)
        #expect(desc.count == 3)
        #expect(desc.contains(c1))
        #expect(desc.contains(c2))
        #expect(desc.contains(grandChild))
    }
}
