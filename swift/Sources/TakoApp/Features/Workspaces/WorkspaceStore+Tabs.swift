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

/// Which workspace each tab belongs to, and in what order.
extension WorkspaceStore {
    struct TabPlace: Equatable {
        let workspace: UUID
        let rank: Int
    }

    /// Rebuilds `tabPlaces` from `workspaces`. A tab listed twice belongs
    /// where it is listed first.
    func indexTabs() {
        var places: [String: TabPlace] = [:]
        for ws in workspaces {
            for (rank, id) in ws.tabIdentifiers.enumerated() where places[id] == nil {
                places[id] = TabPlace(workspace: ws.id, rank: rank)
            }
        }
        tabPlaces = places
    }

    /// The tab's place in the order of workspace `id`, or nil when it is not
    /// one of that workspace's tabs.
    public func rank(ofTab tabIdentifier: String, in id: UUID) -> Int? {
        tabPlaces[tabIdentifier].flatMap { $0.workspace == id ? $0.rank : nil }
    }

    /// Forgets every tab that is not in `live`. Tako calls it once the tabs
    /// of the last run are restored: a list nobody prunes only grows, and
    /// every tab bar draw used to walk it.
    public func pruneTabs(keeping live: Set<String>) {
        var next = workspaces
        for i in next.indices {
            next[i].tabIdentifiers.removeAll { !live.contains($0) }
            if let active = next[i].activeTabIdentifier, !live.contains(active) {
                next[i].activeTabIdentifier = next[i].tabIdentifiers.first
            }
        }
        guard next != workspaces else { return }
        workspaces = next
        save()
    }

    // MARK: - Tab Management

    public func assignTab(tabIdentifier: String, to workspaceId: UUID, at index: Int? = nil) {
        guard workspace(for: workspaceId) != nil else { return }

        for i in 0..<workspaces.count {
            workspaces[i].tabIdentifiers.removeAll { $0 == tabIdentifier }
            if workspaces[i].activeTabIdentifier == tabIdentifier {
                workspaces[i].activeTabIdentifier = workspaces[i].tabIdentifiers.first
            }
        }

        if let targetIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            if let index, index >= 0, index <= workspaces[targetIndex].tabIdentifiers.count {
                workspaces[targetIndex].tabIdentifiers.insert(tabIdentifier, at: index)
            } else {
                workspaces[targetIndex].tabIdentifiers.append(tabIdentifier)
            }
            if workspaces[targetIndex].activeTabIdentifier == nil {
                workspaces[targetIndex].activeTabIdentifier = tabIdentifier
            }
        }

        save()
        NotificationCenter.default.post(name: .takoTabsDidChange, object: self)
    }

    public func removeTab(tabIdentifier: String) {
        var changed = false
        for i in 0..<workspaces.count {
            if let idx = workspaces[i].tabIdentifiers.firstIndex(of: tabIdentifier) {
                workspaces[i].tabIdentifiers.remove(at: idx)
                if workspaces[i].activeTabIdentifier == tabIdentifier {
                    workspaces[i].activeTabIdentifier = workspaces[i].tabIdentifiers.first
                }
                changed = true
            }
        }
        if changed {
            save()
            NotificationCenter.default.post(name: .takoTabsDidChange, object: self)
        }
    }

    public func reorderTabs(in workspaceId: UUID, newOrder: [String]) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        var ordered: [String] = []
        for id in newOrder {
            if !ordered.contains(id) {
                ordered.append(id)
            }
        }
        // Append any unmentioned tabs to the end
        for id in workspaces[index].tabIdentifiers where !ordered.contains(id) {
            ordered.append(id)
        }
        workspaces[index].tabIdentifiers = ordered
        save()
        NotificationCenter.default.post(name: .takoTabsDidChange, object: self)
    }

    /// The tab chosen in a workspace. Choosing the chosen one again -- a tab
    /// switch asks twice -- changes nothing and writes nothing.
    public func setActiveTab(tabIdentifier: String, in workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let oldTab = workspaces[index].activeTabIdentifier
        // Preserve a remembered selection while AppKit is ordering windows;
        // its temporary key-window notifications are not user selections.
        if workspaceSwitchDepth > 0, let oldTab, workspaces[index].tabIdentifiers.contains(oldTab) { return }
        guard oldTab != tabIdentifier else { return }
        workspaces[index].activeTabIdentifier = tabIdentifier
        nextTransitionSequence += 1
        recentTabTransitions.append(TabTransition(
            sequence: nextTransitionSequence,
            workspaceId: workspaceId,
            fromId: oldTab ?? "",
            toId: tabIdentifier,
            timestamp: ProcessInfo.processInfo.systemUptime
        ))
        if recentTabTransitions.count > maxTransitionHistory {
            recentTabTransitions.removeFirst(recentTabTransitions.count - maxTransitionHistory)
        }
        save()
    }
}
