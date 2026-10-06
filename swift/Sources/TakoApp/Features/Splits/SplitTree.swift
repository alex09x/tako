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

/// SplitTree represents a tree of views that can be divided.
struct SplitTree<ViewType: NSView & Codable & Identifiable> {
    /// The root of the tree. This can be nil to indicate the tree is empty.
    let root: Node?

    /// The node that is currently zoomed. A zoomed split is expected to take up the full
    /// size of the view area where the splits are shown.
    let zoomed: Node?

    /// A single node in the tree is either a leaf node (a view) or a split (has a
    /// left/right or top/bottom).
    indirect enum Node: Codable {
        case leaf(view: ViewType)
        case split(Split)

        struct Split: Equatable, Codable {
            let direction: Direction
            let ratio: Double
            let left: Node
            let right: Node
        }
    }

    enum Direction: Codable {
        case horizontal // Splits are laid out left and right
        case vertical // Splits are laid out top and bottom
    }

    /// The path to a specific node in the tree.
    struct Path: Codable {
        let path: [Component]

        var isEmpty: Bool { path.isEmpty }

        enum Component: Codable {
            case left
            case right
        }
    }

    /// Spatial representation of the split tree. This can be used to better understand
    /// its physical representation to perform tasks such as navigation.
    struct Spatial {
        let slots: [Slot]

        /// A single slot within the spatial mapping of a tree. Note that the bounds are
        /// _relative_. They can't be mapped to physical pixels because the SplitTree
        /// isn't aware of actual rendering. But relative to each other the bounds are
        /// correct.
        struct Slot {
            let node: Node
            let bounds: CGRect
        }

        /// Direction for spatial navigation within the split tree.
        enum Direction {
            case left
            case right
            case up
            case down
        }
    }

    enum SplitError: Error {
        case viewNotFound
    }

    enum NewDirection {
        case left
        case right
        case down
        case up
    }

    /// The direction that focus can move from a node.
    enum FocusDirection {
        // Follow a consistent tree-like structure.
        case previous
        case next

        // Spatially-aware navigation targets. These take into account the
        // layout to find the spatially correct node to move to. Spatial navigation
        // is always from the top-left corner for now.
        case spatial(Spatial.Direction)
    }
}

