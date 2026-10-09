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

class MockView: NSView, Codable, Identifiable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    enum CodingKeys: CodingKey { case id }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        super.init(frame: .zero)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
    }
}

struct SplitTreeTests {
    /// Creates a two-view horizontal split tree (view1 | view2).
    static func makeHorizontalSplit() throws -> (SplitTree<MockView>, MockView, MockView) {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        return (tree, view1, view2)
    }

    /// Creates a two-view horizontal split tree (view1 | view2).
    func makeHorizontalSplit() throws -> (SplitTree<MockView>, MockView, MockView) {
        try Self.makeHorizontalSplit()
    }

    // MARK: - Empty and Non-Empty

    @Test func emptyTreeIsEmpty() {
        let tree = SplitTree<MockView>()
        #expect(tree.isEmpty)
    }

    @Test func nonEmptyTreeIsNotEmpty() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(!tree.isEmpty)
    }

    @Test func isNotSplit() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(!tree.isSplit)
    }

    @Test func isSplit() throws {
        let (tree, _, _) = try makeHorizontalSplit()
        #expect(tree.isSplit)
    }

    // MARK: - Contains and Find

    @Test func treeContainsView() {
        let view = MockView()
        let tree = SplitTree<MockView>(view: view)
        #expect(tree.contains(.leaf(view: view)))
    }

    @Test func treeDoesNotContainView() {
        let view = MockView()
        let tree = SplitTree<MockView>()
        #expect(!tree.contains(.leaf(view: view)))
    }

    @Test func findsInsertedView() throws {
        let (tree, view1, _) = try makeHorizontalSplit()
        #expect((tree.find(id: view1.id) != nil))
    }

    @Test func doesNotFindUninsertedView() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect((tree.find(id: view2.id) == nil))
    }

    // MARK: - Removing and Replacing

    @Test func treeDoesNotContainRemovedView() throws {
        var (tree, view1, view2) = try makeHorizontalSplit()
        tree = tree.removing(.leaf(view: view1))
        #expect(!tree.contains(.leaf(view: view1)))
        #expect(tree.contains(.leaf(view: view2)))
    }

    @Test func removingNonexistentNodeLeavesTreeUnchanged() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        let result = tree.removing(.leaf(view: view2))
        #expect(result.contains(.leaf(view: view1)))
        #expect(!result.isEmpty)
    }

    @Test func replacingViewShouldRemoveAndInsertView() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        #expect(tree.contains(.leaf(view: view2)))
        let result = try tree.replacing(node: .leaf(view: view2), with: .leaf(view: view3))
        #expect(result.contains(.leaf(view: view1)))
        #expect(!result.contains(.leaf(view: view2)))
        #expect(result.contains(.leaf(view: view3)))
    }

    @Test func replacingViewWithItselfShouldBeAValidOperation() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let result = try tree.replacing(node: .leaf(view: view2), with: .leaf(view: view2))
        #expect(result.contains(.leaf(view: view1)))
        #expect(result.contains(.leaf(view: view2)))
    }

    // MARK: - Focus Target

    @Test func focusTargetOnEmptyTreeReturnsNil() {
        let tree = SplitTree<MockView>()
        let view = MockView()
        let target = tree.focusTarget(for: .next, from: .leaf(view: view))
        #expect(target == nil)
    }

    @Test func focusTargetShouldFindNextFocusedNode() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let target = tree.focusTarget(for: .next, from: .leaf(view: view1))
        #expect(target === view2)
    }

    @Test func focusTargetShouldFindItselfWhenOnlyView() throws {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        let target = tree.focusTarget(for: .next, from: .leaf(view: view1))
        #expect(target === view1)
    }

    // When there's no next view, wraps around to the first
    @Test func focusTargetShouldHandleWrappingForNextNode() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let target = tree.focusTarget(for: .next, from: .leaf(view: view2))
        #expect(target === view1)
    }

    @Test func focusTargetShouldFindPreviousFocusedNode() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let target = tree.focusTarget(for: .previous, from: .leaf(view: view2))
        #expect(target === view1)
    }

    @Test func focusTargetShouldFindSpatialFocusedNode() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let target = tree.focusTarget(for: .spatial(.left), from: .leaf(view: view2))
        #expect(target === view1)
    }

    // MARK: - Equalized

    @Test func equalizedAdjustsRatioByLeafCount() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view2, direction: .right)

        guard case .split(let before) = tree.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(before.ratio - 0.5) < 0.001)

        let equalized = tree.equalized()

        if case .split(let s) = equalized.root {
            #expect(abs(s.ratio - 1.0/3.0) < 0.001)
        }
    }

    // MARK: - Resizing

    @Test(arguments: [
        // (resizeDirection, insertDirection, bounds, pixels, expectedRatio)
        (SplitTree<MockView>.Spatial.Direction.right, SplitTree<MockView>.NewDirection.right,
         CGRect(x: 0, y: 0, width: 1000, height: 500), UInt16(100), 0.6),
        (.left, .right,
         CGRect(x: 0, y: 0, width: 1000, height: 500), UInt16(50), 0.45),
        (.down, .down,
         CGRect(x: 0, y: 0, width: 500, height: 1000), UInt16(200), 0.7),
        (.up, .down,
         CGRect(x: 0, y: 0, width: 500, height: 1000), UInt16(50), 0.45),
    ])
    func resizingAdjustsRatio(
        resizeDirection: SplitTree<MockView>.Spatial.Direction,
        insertDirection: SplitTree<MockView>.NewDirection,
        bounds: CGRect,
        pixels: UInt16,
        expectedRatio: Double
    ) throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: insertDirection)

        let resized = try tree.resizing(node: .leaf(view: view1), by: pixels, in: resizeDirection, with: bounds)

        guard case .split(let s) = resized.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(s.ratio - expectedRatio) < 0.001)
    }

    // MARK: - Codable

    @Test func encodingAndDecodingPreservesTree() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree<MockView>.self, from: data)
        #expect(decoded.find(id: view1.id) != nil)
        #expect(decoded.find(id: view2.id) != nil)
        #expect(decoded.isSplit)
    }

    @Test func encodingAndDecodingPreservesZoomedPath() throws {
        let (tree, _, view2) = try makeHorizontalSplit()
        let treeWithZoomed = SplitTree<MockView>(root: tree.root, zoomed: .leaf(view: view2))

        let data = try JSONEncoder().encode(treeWithZoomed)
        let decoded = try JSONDecoder().decode(SplitTree<MockView>.self, from: data)

        #expect(decoded.zoomed != nil)
        if case .leaf(let zoomedView) = decoded.zoomed! {
            #expect(zoomedView.id == view2.id)
        } else {
            Issue.record("unexpected node type")
        }
    }


}
