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

// MARK: SplitTree

extension SplitTree {
    var isEmpty: Bool {
        root == nil
    }

    /// Returns true if this tree is split.
    var isSplit: Bool {
        if case .split = root { true } else { false }
    }

    init() {
        self.init(root: nil, zoomed: nil)
    }

    init(view: ViewType) {
        self.init(root: .leaf(view: view), zoomed: nil)
    }

    /// Checks if the tree contains the specified node.
    ///
    /// Note that SplitTree implements Sequence on views so there's already a `contains`
    /// for views too.
    ///
    /// - Parameter node: The node to search for in the tree
    /// - Returns: True if the node exists in the tree, false otherwise
    func contains(_ node: Node) -> Bool {
        guard let root else { return false }
        return root.path(to: node) != nil
    }

    /// Insert a new view at the given view point by creating a split in the given direction.
    /// This will always reset the zoomed state of the tree.
    func inserting(view: ViewType, at: ViewType, direction: NewDirection) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }
        return .init(
            root: try root.inserting(view: view, at: at, direction: direction),
            zoomed: nil)
    }
    /// Find a node containing a view with the specified ID.
    /// - Parameter id: The ID of the view to find
    /// - Returns: The node containing the view if found, nil otherwise
    func find(id: ViewType.ID) -> Node? {
        guard let root else { return nil }
        return root.find(id: id)
    }

    /// Remove a node from the tree. If the node being removed is part of a split,
    /// the sibling node takes the place of the parent split.
    func removing(_ target: Node) -> Self {
        guard let root else { return self }

        // If we're removing the root itself, return an empty tree
        if root == target {
            return .init(root: nil, zoomed: nil)
        }

        // Otherwise, try to remove from the tree
        let newRoot = root.remove(target)

        // Update zoomed if it was the removed node
        let newZoomed = (zoomed == target) ? nil : zoomed

        return .init(root: newRoot, zoomed: newZoomed)
    }

    /// Replace a node in the tree with a new node.
    func replacing(node: Node, with newNode: Node) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }

        // Get the path to the node we want to replace
        guard let path = root.path(to: node) else {
            throw SplitError.viewNotFound
        }

        // Replace the node
        let newRoot = try root.replacingNode(at: path, with: newNode)

        // Update zoomed if it was the replaced node
        let newZoomed = (zoomed == node) ? newNode : zoomed

        return .init(root: newRoot, zoomed: newZoomed)
    }

    /// Find the next view to focus based on the current focused node and direction
    func focusTarget(for direction: FocusDirection, from currentNode: Node) -> ViewType? {
        guard let root else { return nil }

        switch direction {
        case .previous:
            // For previous, we traverse in order and find the previous leaf from our leftmost
            let allLeaves = root.leaves()
            let currentView = currentNode.leftmostLeaf()
            guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
                // Shouldn't be possible leftmostLeaf can't return something that doesn't exist!
                return nil
            }
            let index = allLeaves.indexWrapping(before: currentIndex)
            return allLeaves[index]

        case .next:
            // For previous, we traverse in order and find the next leaf from our rightmost
            let allLeaves = root.leaves()
            let currentView = currentNode.rightmostLeaf()
            guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
                return nil
            }
            let index = allLeaves.indexWrapping(after: currentIndex)
            return allLeaves[index]

        case .spatial(let spatialDirection):
            // Get spatial representation and find best candidate
            let spatial = root.spatial()
            let nodes = spatial.slots(in: spatialDirection, from: currentNode)

            // If we have no nodes in the direction specified then we don't do
            // anything.
            if nodes.isEmpty {
                return nil
            }

            // Extract the view from the best candidate node. The best candidate
            // node is the closest leaf node. If we have no leaves (impossible?)
            // just use the first node.
            let bestNode = nodes.first(where: {
                if case .leaf = $0.node { return true } else { return false }
            }) ?? nodes[0]
            switch bestNode.node {
            case .leaf(let view):
                return view

            case .split:
                // If the best candidate is a split node, use its the leaf/rightmost
                // depending on our spatial direction.
                return switch spatialDirection {
                case .up, .left: bestNode.node.leftmostLeaf()
                case .down, .right: bestNode.node.rightmostLeaf()
                }
            }
        }
    }

    /// Equalize all splits in the tree so that each split's ratio is based on the
    /// relative weight (number of leaves) of its children.
    func equalized() -> Self {
        guard let root else { return self }
        let newRoot = root.equalize()
        return .init(root: newRoot, zoomed: zoomed)
    }

    /// Resize a node in the tree by the given pixel amount in the specified direction.
    ///
    /// This method adjusts the split ratios of the tree to accommodate the requested resize
    /// operation. For up/down resizing, it finds the nearest parent vertical split and adjusts
    /// its ratio. For left/right resizing, it finds the nearest parent horizontal split.
    /// The bounds parameter is used to construct the spatial tree representation which is
    /// needed to calculate the current pixel dimensions.
    ///
    /// This will always reset the zoomed state.
    ///
    /// - Parameters:
    ///   - node: The node to resize
    ///   - by: The number of pixels to resize by
    ///   - direction: The direction to resize in (up, down, left, right)
    ///   - bounds: The bounds used to construct the spatial tree representation
    /// - Returns: A new SplitTree with the adjusted split ratios
    /// - Throws: SplitError.viewNotFound if the node is not found in the tree or no suitable parent split exists
    func resizing(node: Node, by pixels: UInt16, in direction: Spatial.Direction, with bounds: CGRect) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }

        // Find the path to the target node
        guard let path = root.path(to: node) else {
            throw SplitError.viewNotFound
        }

        // Determine which type of split we need to find based on resize direction
        let targetSplitDirection: Direction = switch direction {
        case .up, .down: .vertical
        case .left, .right: .horizontal
        }

        // Find the nearest parent split of the correct type by walking up the path
        var splitPath: Path?
        var splitNode: Node?

        for i in stride(from: path.path.count - 1, through: 0, by: -1) {
            let parentPath = Path(path: Array(path.path.prefix(i)))
            if let parent = root.node(at: parentPath), case .split(let split) = parent {
                if split.direction == targetSplitDirection {
                    splitPath = parentPath
                    splitNode = parent
                    break
                }
            }
        }

        guard let splitPath = splitPath,
              let splitNode = splitNode,
              case .split(let split) = splitNode else {
            throw SplitError.viewNotFound
        }

        // Get current spatial representation to calculate pixel dimensions
        let spatial = root.spatial(within: bounds.size)
        guard let splitSlot = spatial.slots.first(where: { $0.node == splitNode }) else {
            throw SplitError.viewNotFound
        }

        // Calculate the new ratio based on pixel change
        let pixelOffset = Double(pixels)
        let newRatio: Double

        switch (split.direction, direction) {
        case (.horizontal, .left):
            // Moving left boundary: decrease left side
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio - (pixelOffset / splitSlot.bounds.width)))
        case (.horizontal, .right):
            // Moving right boundary: increase left side
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio + (pixelOffset / splitSlot.bounds.width)))
        case (.vertical, .up):
            // Moving top boundary: decrease top side
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio - (pixelOffset / splitSlot.bounds.height)))
        case (.vertical, .down):
            // Moving bottom boundary: increase top side
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio + (pixelOffset / splitSlot.bounds.height)))
        default:
            // Direction doesn't match split type - shouldn't happen due to earlier logic
            throw SplitError.viewNotFound
        }

        // Create new split with adjusted ratio
        let newSplit = Node.Split(
            direction: split.direction,
            ratio: newRatio,
            left: split.left,
            right: split.right
        )

        // Replace the split node with the new one
        let newRoot = try root.replacingNode(at: splitPath, with: .split(newSplit))
        return .init(root: newRoot, zoomed: nil)
    }

    /// Returns the total bounds of the split hierarchy using NSView bounds.
    /// Ignores x/y coordinates and assumes views are laid out in a perfect grid.
    /// Also ignores any possible padding between views.
    /// - Returns: The total width and height needed to contain all views
    func viewBounds() -> CGSize {
        guard let root else { return .zero }
        return root.viewBounds()
    }
}

