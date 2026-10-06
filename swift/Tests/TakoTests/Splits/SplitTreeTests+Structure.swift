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
    // MARK: - Collection Conformance

    @Test func treeIteratesLeavesInOrder() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view2, direction: .right)

        #expect(tree.startIndex == 0)
        #expect(tree.endIndex == 3)
        #expect(tree.index(after: 0) == 1)

        #expect(tree[0] === view1)
        #expect(tree[1] === view2)
        #expect(tree[2] === view3)

        var ids: [UUID] = []
        for view in tree {
            ids.append(view.id)
        }
        #expect(ids == [view1.id, view2.id, view3.id])
    }

    @Test func emptyTreeCollectionProperties() {
        let tree = SplitTree<MockView>()

        #expect(tree.startIndex == 0)
        #expect(tree.endIndex == 0)

        var count = 0
        for _ in tree {
            count += 1
        }
        #expect(count == 0)
    }

    // MARK: - Structural Identity

    @Test func structuralIdentityIsReflexive() throws {
        let (tree, _, _) = try makeHorizontalSplit()
        #expect(tree.structuralIdentity == tree.structuralIdentity)
    }

    @Test func structuralIdentityComparesShapeNotRatio() throws {
        let (tree, view1, _) = try makeHorizontalSplit()

        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let resized = try tree.resizing(node: .leaf(view: view1), by: 100, in: .right, with: bounds)
        #expect(tree.structuralIdentity == resized.structuralIdentity)
    }

    @Test func structuralIdentityForDifferentStructures() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let expanded = try tree.inserting(view: view3, at: view2, direction: .down)
        #expect(tree.structuralIdentity != expanded.structuralIdentity)
    }

    @Test func structuralIdentityIdentifiesDifferentOrdersShapes() throws {
        let (tree, _, _) = try makeHorizontalSplit()

        let (otherTree, _, _) = try makeHorizontalSplit()
        #expect(tree.structuralIdentity != otherTree.structuralIdentity)
    }

    // MARK: - View Bounds

    @Test func viewBoundsReturnsLeafViewSize() {
        let view1 = MockView()
        view1.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let tree = SplitTree<MockView>(view: view1)

        let bounds = tree.viewBounds()
        #expect(bounds.width == 500)
        #expect(bounds.height == 300)
    }

    @Test func viewBoundsReturnsZeroForEmptyTree() {
        let tree = SplitTree<MockView>()
        let bounds = tree.viewBounds()

        #expect(bounds.width == 0)
        #expect(bounds.height == 0)
    }

    @Test func viewBoundsHorizontalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        view1.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view2.frame = NSRect(x: 0, y: 0, width: 200, height: 500)
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let bounds = tree.viewBounds()
        #expect(bounds.width == 600)
        #expect(bounds.height == 500)
    }

    @Test func viewBoundsVerticalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        view1.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        view2.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        let bounds = tree.viewBounds()
        #expect(bounds.width == 500)
        #expect(bounds.height == 600)
    }

    // MARK: - Node

    @Test func nodeFindsLeaf() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        let node = tree.root?.node(view: view1)
        #expect(node != nil)
        #expect(node == .leaf(view: view1))
    }

    @Test func nodeFindsLeavesInSplitTree() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()

        #expect(tree.root?.node(view: view1) == .leaf(view: view1))
        #expect(tree.root?.node(view: view2) == .leaf(view: view2))
    }

    @Test func nodeReturnsNilForMissingView() {
        let view1 = MockView()
        let view2 = MockView()

        let tree = SplitTree<MockView>(view: view1)
        #expect(tree.root?.node(view: view2) == nil)
    }

    @Test func resizingUpdatesRatio() throws {
        let (tree, _, _) = try makeHorizontalSplit()

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        let resized = SplitTree<MockView>.Node.split(s).resizing(to: 0.7)
        guard case .split(let resizedSplit) = resized else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(resizedSplit.ratio - 0.7) < 0.001)
    }

    @Test func resizingLeavesLeafUnchanged() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }
        let resized = root.resizing(to: 0.7)
        #expect(resized == root)
    }

    // MARK: - Spatial

    @Test(arguments: [
        (SplitTree<MockView>.Spatial.Direction.left, SplitTree<MockView>.NewDirection.right),
        (.right, .right),
        (.up, .down),
        (.down, .down),
    ])
    func doesBorderEdge(
        side: SplitTree<MockView>.Spatial.Direction,
        insertDirection: SplitTree<MockView>.NewDirection
    ) throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: insertDirection)

        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))

        // view1 borders left/up; view2 borders right/down
        let (borderView, nonBorderView): (MockView, MockView) =
            (side == .right || side == .down) ? (view2, view1) : (view1, view2)
        #expect(spatial.doesBorder(side: side, from: .leaf(view: borderView)))
        #expect(!spatial.doesBorder(side: side, from: .leaf(view: nonBorderView)))
    }


}
