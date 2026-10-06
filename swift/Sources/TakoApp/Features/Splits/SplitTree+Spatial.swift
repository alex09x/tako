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

// MARK: SplitTree.Node Spatial

extension SplitTree.Node {
    /// Returns the spatial representation of this node and its subtree.
    ///
    /// This method creates a `Spatial` representation that maps the logical split tree structure
    /// to 2D coordinate space. The coordinate system uses (0,0) as the top-left corner with
    /// positive X extending right and positive Y extending down.
    ///
    /// The spatial representation provides:
    /// - Relative bounds for each node based on split ratios
    /// - Grid-like dimensions where each split adds 1 to the column/row count
    /// - Accurate positioning that reflects the actual layout structure
    ///
    /// The bounds are pixel perfect based on assuming that each row and column are 1 pixel
    /// tall or wide, respectively. This needs to be scaled up to the proper bounds for a real
    /// layout.
    ///
    /// Example:
    /// ```
    /// // For a layout like:
    /// // +--------+----+
    /// // |   A    | B  |
    /// // +--------+----+
    /// // |   C    | D  |
    /// // +--------+----+
    /// //
    /// // The spatial representation would have:
    /// // - Total dimensions: (width: 2, height: 2)
    /// // - Node bounds based on actual split ratios
    /// ```
    ///
    /// - Parameter bounds: Optional size constraints for the spatial representation. If nil, uses artificial dimensions based
    ///   on grid layout
    /// - Returns: A `Spatial` struct containing all slots with their calculated bounds
    func spatial(within bounds: CGSize? = nil) -> SplitTree.Spatial {
        // If we're not given bounds, we use artificial dimensions based on
        // the total width/height in columns/rows.
        let width: Double
        let height: Double
        if let bounds {
            width = bounds.width
            height = bounds.height
        } else {
            let (w, h) = self.dimensions()
            width = Double(w)
            height = Double(h)
        }

        // Calculate slots with relative bounds
        let slots = spatialSlots(in: CGRect(x: 0, y: 0, width: width, height: height))
        return SplitTree.Spatial(slots: slots)
    }

    /// Calculates the grid dimensions (columns and rows) needed to represent this subtree.
    ///
    /// This method recursively analyzes the split tree structure to determine how many
    /// columns and rows are needed to represent the layout in a 2D grid. Each leaf node
    /// occupies one grid cell (1×1), and each split extends the grid in one direction:
    ///
    /// - **Horizontal splits**: Add columns (increase width)
    /// - **Vertical splits**: Add rows (increase height)
    ///
    /// The calculation rules are:
    /// - **Leaf nodes**: Always (1, 1) - one column, one row
    /// - **Horizontal splits**: Width = sum of children widths, Height = max of children heights
    /// - **Vertical splits**: Width = max of children widths, Height = sum of children heights
    ///
    /// Example:
    /// ```
    /// // Single leaf: (1, 1)
    /// // Horizontal split with 2 leaves: (2, 1)
    /// // Vertical split with 2 leaves: (1, 2)
    /// // Complex layout with both: (2, 2) or larger
    /// ```
    ///
    /// - Returns: A tuple containing (width: columns, height: rows) as unsigned integers
    private func dimensions() -> (width: UInt, height: UInt) {
        switch self {
        case .leaf:
            return (1, 1)

        case .split(let split):
            let leftDimensions = split.left.dimensions()
            let rightDimensions = split.right.dimensions()

            switch split.direction {
            case .horizontal:
                // Horizontal split: width is sum, height is max
                return (
                    width: leftDimensions.width + rightDimensions.width,
                    height: Swift.max(leftDimensions.height, rightDimensions.height)
                )

            case .vertical:
                // Vertical split: height is sum, width is max
                return (
                    width: Swift.max(leftDimensions.width, rightDimensions.width),
                    height: leftDimensions.height + rightDimensions.height
                )
            }
        }
    }

    /// Calculates the spatial slots (nodes with bounds) for this subtree within the given bounds.
    ///
    /// This method recursively traverses the split tree and calculates the precise bounds
    /// for each node based on the split ratios and directions. The bounds are calculated
    /// relative to the provided bounds rectangle.
    ///
    /// The calculation process:
    /// 1. **Leaf nodes**: Create a single slot with the provided bounds
    /// 2. **Split nodes**:
    ///    - Divide the bounds according to the split ratio and direction
    ///    - Create a slot for the split node itself
    ///    - Recursively calculate slots for both children
    ///    - Return all slots combined
    ///
    /// Split ratio interpretation:
    /// - **Horizontal splits**: Ratio determines left/right width distribution
    ///   - Left child gets `ratio * width`
    ///   - Right child gets `(1 - ratio) * width`
    /// - **Vertical splits**: Ratio determines top/bottom height distribution
    ///   - Top (left) child gets `ratio * height`
    ///   - Bottom (right) child gets `(1 - ratio) * height`
    ///
    /// Coordinate system: (0,0) is top-left, positive X goes right, positive Y goes down.
    ///
    /// - Parameter bounds: The bounding rectangle to subdivide for this subtree
    /// - Returns: An array of `Spatial.Slot` objects, each containing a node and its bounds
    private func spatialSlots(in bounds: CGRect) -> [SplitTree.Spatial.Slot] {
        switch self {
        case .leaf:
            // A leaf takes up our full bounds.
            return [.init(node: self, bounds: bounds)]

        case .split(let split):
            let leftBounds: CGRect
            let rightBounds: CGRect

            switch split.direction {
            case .horizontal:
                // Split horizontally: left | right using the ratio
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
                // Split vertically: top / bottom using the ratio
                // Top-left is (0,0), so top (left) gets the upper portion
                let splitY = bounds.minY + bounds.height * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: bounds.height * split.ratio
                )
                rightBounds = CGRect(
                    x: bounds.minX,
                    y: splitY,
                    width: bounds.width,
                    height: bounds.height * (1 - split.ratio)
                )
            }

            // Recursively calculate slots for children and include a slot for this split
            var slots: [SplitTree.Spatial.Slot] = [.init(node: self, bounds: bounds)]
            slots += split.left.spatialSlots(in: leftBounds)
            slots += split.right.spatialSlots(in: rightBounds)

            return slots
        }
    }
}

// MARK: SplitTree.Spatial

extension SplitTree.Spatial {
    /// Returns all slots in the specified direction relative to the reference node.
    ///
    /// This method finds all slots positioned in the given direction from the reference node:
    /// - **Left**: Slots with bounds to the left of the reference node
    /// - **Right**: Slots with bounds to the right of the reference node
    /// - **Up**: Slots with bounds above the reference node (Y=0 is top)
    /// - **Down**: Slots with bounds below the reference node
    ///
    /// Results are sorted by 2D euclidean distance from the reference node, with closest slots first.
    /// Distance is calculated from the top-left corners of the bounds, prioritizing nodes that are
    /// closer in both dimensions.
    ///
    /// **Important**: The returned array contains both split nodes and leaf nodes. When using this
    /// for navigation or focus management, you typically want to filter for leaf nodes first, as they
    /// represent the actual views that can receive focus. Split nodes are included in the results
    /// because they have bounds and occupy space in the layout, but they are structural elements
    /// that cannot themselves be focused. If no leaf nodes are found in the results, you may need
    /// to traverse into a split node to find its appropriate leaf child.
    ///
    /// - Parameters:
    ///   - direction: The direction to search for slots
    ///   - referenceNode: The node to use as the reference point
    /// - Returns: An array of slots in the specified direction, sorted by 2D distance (closest first)
    func slots(in direction: Direction, from referenceNode: SplitTree.Node) -> [Slot] {
        guard let refSlot = slots.first(where: { $0.node == referenceNode }) else { return [] }

        // Helper function to calculate 2D euclidean distance between top-left corners of two rectangles
        func distance(from rect1: CGRect, to rect2: CGRect) -> Double {
            // Calculate distance between top-left corners
            let dx = rect2.minX - rect1.minX
            let dy = rect2.minY - rect1.minY
            return sqrt(dx * dx + dy * dy)
        }

        let result = switch direction {
        case .left:
            // Slots to the left: their right edge is at or left of reference's left edge
            slots.filter {
                $0.node != referenceNode && $0.bounds.maxX <= refSlot.bounds.minX
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }

        case .right:
            // Slots to the right: their left edge is at or right of reference's right edge
            slots.filter {
                $0.node != referenceNode && $0.bounds.minX >= refSlot.bounds.maxX
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }

        case .up:
            // Slots above: their bottom edge is at or above reference's top edge
            slots.filter {
                $0.node != referenceNode && $0.bounds.maxY <= refSlot.bounds.minY
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }

        case .down:
            // Slots below: their top edge is at or below reference's bottom edge
            slots.filter {
                $0.node != referenceNode && $0.bounds.minY >= refSlot.bounds.maxY
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }
        }

        return result
    }

    /// Returns whether the given node borders the specified side of the spatial bounds.
    ///
    /// This method checks if a node's bounds touch the edge of the overall spatial area:
    /// - **Up**: Node's top edge touches the top of the spatial area (Y=0)
    /// - **Down**: Node's bottom edge touches the bottom of the spatial area (Y=maxY)
    /// - **Left**: Node's left edge touches the left of the spatial area (X=0)
    /// - **Right**: Node's right edge touches the right of the spatial area (X=maxX)
    ///
    /// - Parameters:
    ///   - side: The side of the spatial bounds to check
    ///   - node: The node to check if it borders the specified side
    /// - Returns: True if the node borders the specified side, false otherwise
    func doesBorder(side: Direction, from node: SplitTree.Node) -> Bool {
        // Find the slot for this node
        guard let slot = slots.first(where: { $0.node == node }) else { return false }

        // Calculate the overall bounds of all slots
        let overallBounds = slots.reduce(CGRect.null) { result, slot in
            result.union(slot.bounds)
        }

        return switch side {
        case .up:
            slot.bounds.minY == overallBounds.minY
        case .down:
            slot.bounds.maxY == overallBounds.maxY
        case .left:
            slot.bounds.minX == overallBounds.minX
        case .right:
            slot.bounds.maxX == overallBounds.maxX
        }
    }
}

