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

// MARK: Structural Identity

extension SplitTree.Node {
    /// Returns a hashable representation that captures this node's structural identity.
    var structuralIdentity: StructuralIdentity {
        StructuralIdentity(self)
    }

    /// A hashable representation of a node that captures its structural identity.
    ///
    /// This type provides a way to track changes to a node's structure in SwiftUI
    /// by implementing `Hashable` based on:
    /// - The node's hierarchical structure (splits and their directions)
    /// - The identity of view instances in leaf nodes (using object identity)
    /// - The split directions (but not ratios, as those may change slightly)
    ///
    /// This is useful for SwiftUI's `id()` modifier to detect when a node's structure
    /// has changed, triggering appropriate view updates while preserving view identity
    /// for unchanged portions of the tree.
    struct StructuralIdentity: Hashable {
        private let node: SplitTree.Node

        init(_ node: SplitTree.Node) {
            self.node = node
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.node.isStructurallyEqual(to: rhs.node)
        }

        func hash(into hasher: inout Hasher) {
            node.hashStructure(into: &hasher)
        }
    }

    /// Checks if this node is structurally equal to another node.
    /// Two nodes are structurally equal if they have the same tree structure
    /// and the same views (by identity) in the same positions.
    fileprivate func isStructurallyEqual(to other: Node) -> Bool {
        switch (self, other) {
        case let (.leaf(view1), .leaf(view2)):
            // Views must be the same instance
            return view1 === view2

        case let (.split(split1), .split(split2)):
            // Splits must have same direction and structurally equal children
            // Note: We intentionally don't compare ratios as they may change slightly
            return split1.direction == split2.direction &&
                   split1.left.isStructurallyEqual(to: split2.left) &&
                   split1.right.isStructurallyEqual(to: split2.right)

        default:
            // Different node types
            return false
        }
    }

    /// Hash keys for structural identity
    private enum HashKey: UInt8 {
        case leaf = 0
        case split = 1
    }

    /// Hashes the structural identity of this node.
    /// Includes the tree structure and view identities in the hash.
    fileprivate func hashStructure(into hasher: inout Hasher) {
        switch self {
        case .leaf(let view):
            hasher.combine(HashKey.leaf)
            hasher.combine(ObjectIdentifier(view))

        case .split(let split):
            hasher.combine(HashKey.split)
            hasher.combine(split.direction)
            // Note: We intentionally don't hash the ratio
            split.left.hashStructure(into: &hasher)
            split.right.hashStructure(into: &hasher)
        }
    }
}

extension SplitTree {
    /// Returns a hashable representation that captures this tree's structural identity.
    var structuralIdentity: StructuralIdentity {
        StructuralIdentity(self)
    }

    /// A hashable representation of a SplitTree that captures its structural identity.
    ///
    /// This type provides a way to track changes to a SplitTree's structure in SwiftUI
    /// by implementing `Hashable` based on:
    /// - The tree's hierarchical structure (splits and their directions)
    /// - The identity of view instances in leaf nodes (using object identity)
    /// - The zoomed node state (if any)
    ///
    /// This is useful for SwiftUI's `id()` modifier to detect when a tree's structure
    /// has changed, triggering appropriate view updates while preserving view identity
    /// for unchanged portions of the tree.
    ///
    /// Example usage:
    /// ```swift
    /// var body: some View {
    ///     SplitTreeView(tree: splitTree)
    ///         .id(splitTree.structuralIdentity)
    /// }
    /// ```
    struct StructuralIdentity: Hashable {
        private let root: Node?
        private let zoomed: Node?

        init(_ tree: SplitTree) {
            self.root = tree.root
            self.zoomed = tree.zoomed
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            areNodesStructurallyEqual(lhs.root, rhs.root) &&
            areNodesStructurallyEqual(lhs.zoomed, rhs.zoomed)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(0) // Tree marker
            if let root = root {
                root.hashStructure(into: &hasher)
            }
            hasher.combine(1) // Zoomed marker
            if let zoomed = zoomed {
                zoomed.hashStructure(into: &hasher)
            }
        }

        /// Helper to compare optional nodes for structural equality
        private static func areNodesStructurallyEqual(_ lhs: Node?, _ rhs: Node?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case let (node1?, node2?):
                return node1.isStructurallyEqual(to: node2)
            default:
                return false
            }
        }
    }
}
