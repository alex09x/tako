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

// MARK: SplitTree.Node

extension SplitTree.Node {
    typealias Node = SplitTree.Node
    typealias NewDirection = SplitTree.NewDirection
    typealias SplitError = SplitTree.SplitError
    typealias Path = SplitTree.Path

    /// Find a node containing a view with the specified ID.
    /// - Parameter id: The ID of the view to find
    /// - Returns: The node containing the view if found, nil otherwise
    func find(id: ViewType.ID) -> Node? {
        switch self {
        case .leaf(let view):
            return view.id == id ? self : nil

        case .split(let split):
            if let found = split.left.find(id: id) {
                return found
            }

            return split.right.find(id: id)
        }
    }

    /// Returns the node in the tree that contains the given view.
    func node(view: ViewType) -> Node? {
        switch self {
        case .leaf(view):
            return self

        case .split(let split):
            if let result = split.left.node(view: view) {
                return result
            } else if let result = split.right.node(view: view) {
                return result
            }

            return nil

        default:
            return nil
        }
    }

    /// Returns the path to a given node in the tree. If the returned value is nil then the
    /// node doesn't exist.
    func path(to node: Self) -> Path? {
        var components: [Path.Component] = []
        func search(_ current: Self) -> Bool {
            if current == node {
                return true
            }

            switch current {
            case .leaf:
                return false

            case .split(let split):
                // Try left branch
                components.append(.left)
                if search(split.left) {
                    return true
                }
                components.removeLast()

                // Try right branch
                components.append(.right)
                if search(split.right) {
                    return true
                }
                components.removeLast()

                return false
            }
        }

        return search(self) ? Path(path: components) : nil
    }

    /// Returns the node at the given path from this node as root.
    func node(at path: Path) -> Node? {
        if path.isEmpty {
            return self
        }

        guard case .split(let split) = self else {
            return nil
        }

        let component = path.path[0]
        let remainingPath = Path(path: Array(path.path.dropFirst()))

        switch component {
        case .left:
            return split.left.node(at: remainingPath)
        case .right:
            return split.right.node(at: remainingPath)
        }
    }

    /// Inserts a new view into the split tree by creating a split at the location of an existing view.
    ///
    /// This method creates a new split node containing both the existing view and the new view,
    /// The position of the new view relative to the existing view is determined by the direction parameter.
    ///
    /// - Parameters:
    ///   - view: The new view to insert into the tree
    ///   - at: The existing view at whose location the split should be created
    ///   - direction: The direction relative to the existing view where the new view should be placed
    ///
    /// - Note: If the existing view (`at`) is not found in the tree, this method does nothing. We should
    /// maybe throw instead but at the moment we just do nothing.
    func inserting(view: ViewType, at: ViewType, direction: NewDirection) throws -> Self {
        // Get the path to our insertion point. If it doesn't exist we do
        // nothing.
        guard let path = path(to: .leaf(view: at)) else {
            throw SplitError.viewNotFound
        }

        // Determine split direction and which side the new view goes on
        let splitDirection: SplitTree.Direction
        let newViewOnLeft: Bool
        switch direction {
        case .left:
            splitDirection = .horizontal
            newViewOnLeft = true
        case .right:
            splitDirection = .horizontal
            newViewOnLeft = false
        case .up:
            splitDirection = .vertical
            newViewOnLeft = true
        case .down:
            splitDirection = .vertical
            newViewOnLeft = false
        }

        // Create the new split node
        let newNode: Node = .leaf(view: view)
        let existingNode: Node = .leaf(view: at)
        let newSplit: Node = .split(.init(
            direction: splitDirection,
            ratio: 0.5,
            left: newViewOnLeft ? newNode : existingNode,
            right: newViewOnLeft ? existingNode : newNode
        ))

        // Replace the node at the path with the new split
        return try replacingNode(at: path, with: newSplit)
    }

    /// Helper function to replace a node at the given path from the root
    func replacingNode(at path: Path, with newNode: Self) throws -> Self {
        // If path is empty, replace the root
        if path.isEmpty {
            return newNode
        }

        // Otherwise, we need to replace the proper left/right all along
        // the way since Node is a value type (enum). To do that, we need
        // recursion. We can't use a simple iterative approach because we
        // can't update in-place.
        func replaceInner(current: Node, pathOffset: Int) throws -> Node {
            // Base case: if we've consumed the entire path, replace this node
            if pathOffset >= path.path.count {
                return newNode
            }

            // We need to go deeper, so current must be a split for the path
            // to be valid. Otherwise, the path is invalid.
            guard case .split(let split) = current else {
                throw SplitError.viewNotFound
            }

            let component = path.path[pathOffset]
            switch component {
            case .left:
                return .split(.init(
                    direction: split.direction,
                    ratio: split.ratio,
                    left: try replaceInner(current: split.left, pathOffset: pathOffset + 1),
                    right: split.right
                ))
            case .right:
                return .split(.init(
                    direction: split.direction,
                    ratio: split.ratio,
                    left: split.left,
                    right: try replaceInner(current: split.right, pathOffset: pathOffset + 1)
                ))
            }
        }

        return try replaceInner(current: self, pathOffset: 0)
    }

