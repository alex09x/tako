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
import Combine

// MARK: SplitTree.Node Protocols

extension SplitTree.Node: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.leaf(leftView), .leaf(rightView)):
            // Compare NSView instances by object identity
            return leftView === rightView

        case let (.split(split1), .split(split2)):
            return split1 == split2

        default:
            return false
        }
    }
}

// MARK: SplitTree Codable

extension SplitTree.Node {
    enum CodingKeys: String, CodingKey {
        case view
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.view) {
            let view = try container.decode(ViewType.self, forKey: .view)
            self = .leaf(view: view)
        } else if container.contains(.split) {
            let split = try container.decode(Split.self, forKey: .split)
            self = .split(split)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "No valid node type found"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .leaf(let view):
            try container.encode(view, forKey: .view)

        case .split(let split):
            try container.encode(split, forKey: .split)
        }
    }
}

// MARK: SplitTree Sequences

extension SplitTree.Node {
    /// Returns all leaf views in this subtree
    func leaves() -> [ViewType] {
        switch self {
        case .leaf(let view):
            return [view]

        case .split(let split):
            return split.left.leaves() + split.right.leaves()
        }
    }
}

extension SplitTree: Sequence {
    func makeIterator() -> [ViewType].Iterator {
        return root?.leaves().makeIterator() ?? [].makeIterator()
    }
}

extension SplitTree.Node: Sequence {
    func makeIterator() -> [ViewType].Iterator {
        return leaves().makeIterator()
    }
}

// MARK: SplitTree Collection

extension SplitTree: Collection {
    typealias Index = Int
    typealias Element = ViewType

    var startIndex: Int {
        return 0
    }

    var endIndex: Int {
        return root?.leaves().count ?? 0
    }

    subscript(position: Int) -> ViewType {
        precondition(position >= 0 && position < endIndex, "Index out of bounds")
        let leaves = root?.leaves() ?? []
        return leaves[position]
    }

    func index(after i: Int) -> Int {
        precondition(i < endIndex, "Cannot increment index beyond endIndex")
        return i + 1
    }
}

// MARK: SplitTree Combine

extension SplitTree {
    /// Builds a publisher that emits current values for all leaf views keyed by view ID.
    ///
    /// The returned publisher emits a full `[ViewType.ID: Value]` snapshot whenever any leaf view
    /// publishes through the provided publisher key path.
    func valuesPublisher<Value>(
        valueKeyPath: KeyPath<ViewType, Value>,
        publisherKeyPath: KeyPath<ViewType, Published<Value>.Publisher>
    ) -> AnyPublisher<[ViewType.ID: Value], Never> {
        // Flatten the split tree into a list of current leaf views.
        let views = map { $0 }
        guard !views.isEmpty else {
            // If there are no leaves, immediately publish an empty snapshot.
            // `Just([:])` keeps the return type simple and makes downstream usage easy.
            return Just([:]).eraseToAnyPublisher()
        }

        // Capture each view's current value up front.
        // We key by `ViewType.ID` so updates can replace the correct entry later.
        // This avoids waiting for all views to emit before consumers see data.
        let initial = Dictionary(uniqueKeysWithValues: views.map { view in
            (view.id, view[keyPath: valueKeyPath])
        })

        // Build one publisher per view from the requested key path.
        // Each emission is mapped into `(id, value)` so we know which entry changed.
        // `MergeMany` combines all per-view streams into a single update stream.
        let updates = Publishers.MergeMany(views.map { view in
            view[keyPath: publisherKeyPath]
                .map { (view.id, $0) }
                .eraseToAnyPublisher()
        })

        return updates
            // Accumulate updates into a full "latest value per ID" dictionary.
            // This turns incremental events into complete state snapshots.
            .scan(initial) { state, update in
                var state = state
                state[update.0] = update.1
                return state
            }
            // Emit the initial snapshot first so subscribers always get a
            // complete value dictionary immediately upon subscription.
            .prepend(initial)
            // Hide implementation details and expose a stable API type.
            .eraseToAnyPublisher()
    }
}

