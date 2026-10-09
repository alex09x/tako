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

extension SplitTreeTests {
    // MARK: - Calculate View Bounds

    @Test func calculatesViewBoundsForSingleLeaf() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let result = root.calculateViewBounds(in: bounds)
        #expect(result.count == 1)
        #expect(result[0].view === view1)
        #expect(result[0].bounds == bounds)
    }

    @Test func calculatesViewBoundsHorizontalSplit() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let result = root.calculateViewBounds(in: bounds)
        #expect(result.count == 2)

        let leftBounds = result.first { $0.view === view1 }!.bounds
        let rightBounds = result.first { $0.view === view2 }!.bounds
        #expect(leftBounds == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(rightBounds == CGRect(x: 500, y: 0, width: 500, height: 500))
    }

    @Test func calculatesViewBoundsVerticalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let result = root.calculateViewBounds(in: bounds)
        #expect(result.count == 2)

        let topBounds = result.first { $0.view === view1 }!.bounds
        let bottomBounds = result.first { $0.view === view2 }!.bounds
        #expect(topBounds == CGRect(x: 0, y: 500, width: 500, height: 500))
        #expect(bottomBounds == CGRect(x: 0, y: 0, width: 500, height: 500))
    }

    @Test func calculateViewBoundsCustomRatio() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        let resizedRoot = SplitTree<MockView>.Node.split(s).resizing(to: 0.3)
        let container = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let result = resizedRoot.calculateViewBounds(in: container)
        #expect(result.count == 2)

        let leftBounds = result.first { $0.view === view1 }!.bounds
        let rightBounds = result.first { $0.view === view2 }!.bounds
        #expect(leftBounds.width == 300)   // 0.3 * 1000
        #expect(rightBounds.width == 700)   // 0.7 * 1000
        #expect(rightBounds.minX == 300)
    }

    @Test func calculateViewBoundsGrid() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let view4 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view1, direction: .down)
        tree = try tree.inserting(view: view4, at: view2, direction: .down)
        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }
        let container = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let result = root.calculateViewBounds(in: container)
        #expect(result.count == 4)

        let b1 = result.first { $0.view === view1 }!.bounds
        let b2 = result.first { $0.view === view2 }!.bounds
        let b3 = result.first { $0.view === view3 }!.bounds
        let b4 = result.first { $0.view === view4 }!.bounds
        #expect(b1 == CGRect(x: 0, y: 400, width: 500, height: 400))   // top-left
        #expect(b2 == CGRect(x: 500, y: 400, width: 500, height: 400)) // top-right
        #expect(b3 == CGRect(x: 0, y: 0, width: 500, height: 400))     // bottom-left
        #expect(b4 == CGRect(x: 500, y: 0, width: 500, height: 400))   // bottom-right
    }

    @Test(arguments: [
        (SplitTree<MockView>.Spatial.Direction.right, SplitTree<MockView>.NewDirection.right),
        (.left, .right),
        (.down, .down),
        (.up, .down),
    ])
    func slotsFromNode(
        direction: SplitTree<MockView>.Spatial.Direction,
        insertDirection: SplitTree<MockView>.NewDirection
    ) throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: insertDirection)

        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))

        // look from view1 toward view2 for right/down, from view2 toward view1 for left/up
        let (fromView, expectedView): (MockView, MockView) =
            (direction == .right || direction == .down) ? (view1, view2) : (view2, view1)
        let slots = spatial.slots(in: direction, from: .leaf(view: fromView))
        #expect(slots.count == 1)
        #expect(slots[0].node == .leaf(view: expectedView))
    }

    @Test func slotsGridFromTopLeft() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let view4 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view1, direction: .down)
        tree = try tree.inserting(view: view4, at: view2, direction: .down)
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 800))
        let rightSlots = spatial.slots(in: .right, from: .leaf(view: view1))
        let downSlots = spatial.slots(in: .down, from: .leaf(view: view1))
        // slots() returns both split nodes and leaves; split nodes can tie on distance
        #expect(rightSlots.contains { $0.node == .leaf(view: view2) })
        #expect(downSlots.contains { $0.node == .leaf(view: view3) })
    }

    @Test func slotsGridFromBottomRight() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let view4 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view1, direction: .down)
        tree = try tree.inserting(view: view4, at: view2, direction: .down)
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 800))
        let leftSlots = spatial.slots(in: .left, from: .leaf(view: view4))
        let upSlots = spatial.slots(in: .up, from: .leaf(view: view4))
        #expect(leftSlots.contains { $0.node == .leaf(view: view3) })
        #expect(upSlots.contains { $0.node == .leaf(view: view2) })
    }

    @Test func slotsReturnsEmptyWhenNoNodesInDirection() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()

        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        #expect(spatial.slots(in: .left, from: .leaf(view: view1)).isEmpty)
        #expect(spatial.slots(in: .right, from: .leaf(view: view2)).isEmpty)
        #expect(spatial.slots(in: .up, from: .leaf(view: view1)).isEmpty)
        #expect(spatial.slots(in: .down, from: .leaf(view: view2)).isEmpty)
    }

    // Set/Dictionary usage is the only path that exercises StructuralIdentity.hash(into:)
    @Test func structuralIdentityHashableBehavior() throws {
        let (tree, _, _) = try makeHorizontalSplit()
        let id = tree.structuralIdentity

        #expect(id == id)

        var seen: Set<SplitTree<MockView>.StructuralIdentity> = []
        seen.insert(id)
        seen.insert(id)
        #expect(seen.count == 1)

        var cache: [SplitTree<MockView>.StructuralIdentity: String] = [:]
        cache[id] = "two-pane"
        #expect(cache[id] == "two-pane")
    }

    @Test func nodeStructuralIdentityInSet() throws {
        let (tree, _, _) = try makeHorizontalSplit()

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        var nodeIds: Set<SplitTree<MockView>.Node.StructuralIdentity> = []
        nodeIds.insert(tree.root!.structuralIdentity)
        nodeIds.insert(s.left.structuralIdentity)
        nodeIds.insert(s.right.structuralIdentity)
        #expect(nodeIds.count == 3)
    }

    @Test func nodeStructuralIdentityDistinguishesLeaves() throws {
        let (tree, _, _) = try makeHorizontalSplit()

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        var nodeIds: Set<SplitTree<MockView>.Node.StructuralIdentity> = []
        nodeIds.insert(s.left.structuralIdentity)
        nodeIds.insert(s.right.structuralIdentity)
        #expect(nodeIds.count == 2)
    }
}
