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

/// Remove a node from the tree. Returns the modified tree, or nil if removing
    /// the node results in an empty tree.
    func remove(_ target: Node) -> Node? {
        // If we're removing ourselves, return nil
        if self == target {
            return nil
        }

        switch self {
        case .leaf:
            // A leaf that isn't the target stays as is
            return self

        case .split(let split):
            // Neither child is directly the target, so we need to recursively
            // try to remove from both children
            let newLeft = split.left.remove(target)
            let newRight = split.right.remove(target)

            // If both are nil then we remove everything. This shouldn't ever
            // happen because duplicate nodes shouldn't exist, but we want to
            // be robust against it.
            if newLeft == nil && newRight == nil {
                return nil
            } else if newLeft == nil {
                return newRight
            } else if newRight == nil {
                return newLeft
            }

            // Both children still exist after removal
            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: newLeft!,
                right: newRight!
            ))
        }
    }

    /// Resize a split node to the specified ratio.
    /// For leaf nodes, this returns the node unchanged.
    /// For split nodes, this creates a new split with the updated ratio.
    func resizing(to ratio: Double) -> Self {
        switch self {
        case .leaf:
            // Leaf nodes don't have a ratio to resize
            return self

        case .split(let split):
            // Create a new split with the updated ratio
            return .split(.init(
                direction: split.direction,
                ratio: ratio,
                left: split.left,
                right: split.right
            ))
        }
    }

    /// Get the leftmost leaf in this subtree
    func leftmostLeaf() -> ViewType {
        switch self {
        case .leaf(let view):
            return view
        case .split(let split):
            return split.left.leftmostLeaf()
        }
    }

    /// Get the rightmost leaf in this subtree
    func rightmostLeaf() -> ViewType {
        switch self {
        case .leaf(let view):
            return view
        case .split(let split):
            return split.right.rightmostLeaf()
        }
    }

    /// Equalize this node and all its children, returning a new node with splits
    /// adjusted so that each split's ratio is based on the relative weight
    /// (number of leaves) of its children.
    func equalize() -> Node {
        let (equalizedNode, _) = equalizeWithWeight()
        return equalizedNode
    }

    /// Internal helper that equalizes and returns both the node and its weight.
    private func equalizeWithWeight() -> (node: Node, weight: Int) {
        switch self {
        case .leaf:
            // A leaf has weight 1 and doesn't change
            return (self, 1)

        case .split(let split):
            // Calculate weights based on split direction
            let leftWeight = split.left.weightForDirection(split.direction)
            let rightWeight = split.right.weightForDirection(split.direction)

            // Calculate new ratio based on relative weights
            let totalWeight = leftWeight + rightWeight
            let newRatio = Double(leftWeight) / Double(totalWeight)

            // Recursively equalize children
            let (leftNode, _) = split.left.equalizeWithWeight()
            let (rightNode, _) = split.right.equalizeWithWeight()

            // Create new split with equalized ratio
            let newSplit = Split(
                direction: split.direction,
                ratio: newRatio,
                left: leftNode,
                right: rightNode
            )

            return (.split(newSplit), totalWeight)
        }
    }

    /// Calculate weight for equalization based on split direction.
    /// Children with the same direction contribute their full weight,
    /// children with different directions count as 1.
    private func weightForDirection(_ direction: SplitTree.Direction) -> Int {
        switch self {
        case .leaf:
            return 1
        case .split(let split):
            if split.direction == direction {
                return split.left.weightForDirection(direction) + split.right.weightForDirection(direction)
            } else {
                return 1
            }
        }
    }

    /// Calculate the bounds of all views in this subtree based on split ratios
    func calculateViewBounds(in bounds: CGRect) -> [(view: ViewType, bounds: CGRect)] {
        switch self {
        case .leaf(let view):
            return [(view, bounds)]

        case .split(let split):
            // Calculate bounds for left and right based on split direction and ratio
            let leftBounds: CGRect
            let rightBounds: CGRect

            switch split.direction {
            case .horizontal:
                // Split horizontally: left | right
                let splitX = bounds.minX + bounds.width * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width * split.ratio,
                    height: bounds.height
                )
                rightBounds = CGRect(
                    x: splitX,
                    y: bounds.minY,
                    width: bounds.width * (1 - split.ratio),
                    height: bounds.height
                )

            case .vertical:
                // Split vertically: top / bottom
                // Note: In our normalized coordinate system, Y increases upward
                let splitY = bounds.minY + bounds.height * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: splitY,
                    width: bounds.width,
                    height: bounds.height * (1 - split.ratio)
                )
                rightBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: bounds.height * split.ratio
                )
            }

            // Recursively calculate bounds for children
            return split.left.calculateViewBounds(in: leftBounds) +
                   split.right.calculateViewBounds(in: rightBounds)
        }
    }

    /// Returns the total bounds of this subtree using NSView bounds.
    /// Ignores x/y coordinates and assumes views are laid out in a perfect grid.
    /// - Returns: The total width and height needed to contain all views in this subtree
    func viewBounds() -> CGSize {
        switch self {
        case .leaf(let view):
            return view.bounds.size

        case .split(let split):
            let leftBounds = split.left.viewBounds()
            let rightBounds = split.right.viewBounds()

            switch split.direction {
            case .horizontal:
                // Horizontal split: width is sum, height is max
                return CGSize(
                    width: leftBounds.width + rightBounds.width,
                    height: Swift.max(leftBounds.height, rightBounds.height)
                )

            case .vertical:
                // Vertical split: height is sum, width is max
                return CGSize(
                    width: Swift.max(leftBounds.width, rightBounds.width),
                    height: leftBounds.height + rightBounds.height
                )
            }
        }
    }
}

