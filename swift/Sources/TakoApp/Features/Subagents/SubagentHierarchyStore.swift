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
import Foundation

extension Notification.Name {
    public static let takoSubagentHierarchyDidChange = Notification.Name("TakoSubagentHierarchyDidChange")
}

/// Central store for subagent pane hierarchy and context (C5).
/// Tracks parent-child relationships, subagent labels, collapse state,
/// and aggregated child status summaries.
@MainActor
public final class SubagentHierarchyStore: ObservableObject {
    public static let shared = SubagentHierarchyStore()

    /// Mapping of child pane UUID -> parent pane UUID.
    @Published public private(set) var parentByChild: [UUID: UUID] = [:]

    /// Mapping of parent pane UUID -> ordered list of child pane UUIDs.
    @Published public private(set) var childrenByParent: [UUID: [UUID]] = [:]

    /// User-assigned label for subagent child panes (e.g., "worker", "researcher").
    @Published public private(set) var labelByPane: [UUID: String] = [:]

    /// Set of parent pane UUIDs whose child groups are collapsed in tree and sidebar.
    @Published public private(set) var collapsedParents: Set<UUID> = []

    public init() {}

    // MARK: - Hierarchy Management

    /// Registers a child pane under a parent pane with an optional label.
    public func registerChild(childId: UUID, parentId: UUID, label: String? = nil) {
        // If already registered elsewhere, unregister first
        if let oldParent = parentByChild[childId], oldParent != parentId {
            childrenByParent[oldParent]?.removeAll { $0 == childId }
            if childrenByParent[oldParent]?.isEmpty == true {
                childrenByParent.removeValue(forKey: oldParent)
            }
        }

        parentByChild[childId] = parentId
        var list = childrenByParent[parentId] ?? []
        if !list.contains(childId) {
            list.append(childId)
            childrenByParent[parentId] = list
        }

        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            labelByPane[childId] = label
        }

        NotificationCenter.default.post(name: .takoSubagentHierarchyDidChange, object: self)
    }

    /// Unregisters a pane when it is closed.
    public func unregister(paneId: UUID) {
        var changed = false

        // If it was a child:
        if let parent = parentByChild.removeValue(forKey: paneId) {
            childrenByParent[parent]?.removeAll { $0 == paneId }
            if childrenByParent[parent]?.isEmpty == true {
                childrenByParent.removeValue(forKey: parent)
            }
            changed = true
        }

        // If it was a parent:
        if let children = childrenByParent.removeValue(forKey: paneId) {
            for child in children {
                parentByChild.removeValue(forKey: child)
            }
            collapsedParents.remove(paneId)
            changed = true
        }

        if labelByPane.removeValue(forKey: paneId) != nil {
            changed = true
        }

        if collapsedParents.remove(paneId) != nil {
            changed = true
        }

        if changed {
            NotificationCenter.default.post(name: .takoSubagentHierarchyDidChange, object: self)
        }
    }

    public func parent(of childId: UUID) -> UUID? {
        parentByChild[childId]
    }

    public func children(of parentId: UUID) -> [UUID] {
        childrenByParent[parentId] ?? []
    }

    /// Recursively returns all descendant child pane UUIDs under `parentId`.
    public func descendants(of parentId: UUID) -> [UUID] {
        var result: [UUID] = []
        var queue = children(of: parentId)
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if !result.contains(next) {
                result.append(next)
                queue.append(contentsOf: children(of: next))
            }
        }
        return result
    }

    public func hasChildren(_ parentId: UUID) -> Bool {
        !(childrenByParent[parentId]?.isEmpty ?? true)
    }

    public func label(for paneId: UUID) -> String? {
        labelByPane[paneId]
    }

    public func setLabel(for paneId: UUID, label: String?) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed = trimmed, !trimmed.isEmpty {
            labelByPane[paneId] = trimmed
        } else {
            labelByPane.removeValue(forKey: paneId)
        }
        NotificationCenter.default.post(name: .takoSubagentHierarchyDidChange, object: self)
    }

    // MARK: - Collapse State

    public func isCollapsed(_ parentId: UUID) -> Bool {
        collapsedParents.contains(parentId)
    }

    public func setCollapsed(_ parentId: UUID, collapsed: Bool) {
        if collapsed {
            collapsedParents.insert(parentId)
        } else {
            collapsedParents.remove(parentId)
        }
        NotificationCenter.default.post(name: .takoSubagentHierarchyDidChange, object: self)
    }

    public func toggleCollapsed(_ parentId: UUID) {
        setCollapsed(parentId, collapsed: !isCollapsed(parentId))
    }

    // MARK: - Status Summarization

    /// Generates an aggregated status summary for a parent's children.
    /// (e.g., "3 subagents running" or "2 working, 1 done")
    public func statusSummary(for parentId: UUID) -> String? {
        statusSummary(for: parentId, statuses: nil)
    }

    func statusSummary(for parentId: UUID, statuses: [UUID: Tako.PaneStatus]?) -> String? {
        let childIds = children(of: parentId)
        guard !childIds.isEmpty else { return nil }

        var counts: [Tako.PaneStatus: Int] = [:]
        var activeChildCount = 0

        if let statuses = statuses {
            for childId in childIds {
                if let st = statuses[childId] {
                    counts[st, default: 0] += 1
                    activeChildCount += 1
                }
            }
        } else {
            let allPanes = ControlCommands.panes()
            for childId in childIds {
                if let pane = allPanes.first(where: { $0.surface.id == childId }) {
                    let st = pane.surface.crab.paneStatus
                    counts[st, default: 0] += 1
                    activeChildCount += 1
                }
            }
        }

        guard activeChildCount > 0 else { return nil }

        // If all children share the same status:
        if counts.count == 1, let (status, count) = counts.first {
            let noun = count == 1 ? "subagent" : "subagents"
            switch status {
            case .running:
                return "\(count) \(noun) running"
            case .working:
                return "\(count) \(noun) working"
            case .done:
                return "\(count) \(noun) done"
            case .waitingForInput:
                return "\(count) \(noun) waiting for input"
            case .needsApproval:
                return "\(count) \(noun) need approval"
            case .error:
                return "\(count) \(noun) error"
            case .idle:
                return "\(count) \(noun) idle"
            default:
                return "\(count) \(noun) \(status.rawValue)"
            }
        }

        // Multiple distinct statuses: order by significance
        var parts: [String] = []
        let orderedStatuses: [Tako.PaneStatus] = [
            .error, .needsApproval, .waitingForInput, .working, .running, .done, .idle, .disconnected
        ]

        for st in orderedStatuses {
            if let count = counts[st], count > 0 {
                switch st {
                case .working: parts.append("\(count) working")
                case .running: parts.append("\(count) running")
                case .done: parts.append("\(count) done")
                case .error: parts.append("\(count) error")
                case .needsApproval: parts.append("\(count) need approval")
                case .waitingForInput: parts.append("\(count) waiting")
                case .idle: parts.append("\(count) idle")
                default: parts.append("\(count) \(st.rawValue)")
                }
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
