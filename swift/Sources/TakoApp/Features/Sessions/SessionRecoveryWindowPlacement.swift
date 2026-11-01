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

/// Reconstructs a physical window automatically only when saved membership
/// identifies it; otherwise it asks before joining an existing group.
@MainActor
enum SessionRecoveryWindowPlacement {
    enum Decision {
        case existing(NSWindow)
        case newWindow
        case choose([NSWindow])
    }

    static func decide(record: SessionRecord, workspaceID: UUID, groups: [Tako.CustomTabGroup],
                       store: WorkspaceStore) -> Decision {
        let candidates: [[NSWindow]] = groups.compactMap { group in
            let windows = group.windows.filter { !Tako.CustomTabGroup.isClosed($0) }
            return windows.isEmpty ? nil : windows
        }
        func classify(_ matches: [[NSWindow]], preferred: Set<String>) -> Decision {
            let anchors = matches.compactMap { windows in
                windows.first { preferred.contains($0.stableTabIdentifier) }
                    ?? windows.first { (store.workspace(forTab: $0.stableTabIdentifier)?.id ?? WorkspaceStore.defaultWorkspaceId) == workspaceID }
                    ?? windows.first
            }.sorted { $0.stableTabIdentifier < $1.stableTabIdentifier }
            if anchors.isEmpty { return .newWindow }
            if anchors.count == 1 { return .existing(anchors[0]) }
            return .choose(anchors)
        }

        if let saved = record.windowTabIdentifiers {
            // A restored split sibling can legitimately have this same tab
            // ID; it still identifies the physical window group.
            let siblings = Set(saved).union(record.tabIdentifier.map { [$0] } ?? [])
            let matches = candidates.filter { windows in windows.contains { siblings.contains($0.stableTabIdentifier) } }
            if !matches.isEmpty { return classify(matches, preferred: siblings) }
            // The old companions may all be missing, or the only current
            // group may be a newly created startup window. Do not guess.
            if candidates.isEmpty { return .newWindow }
            let possible = candidates.compactMap(\.first).sorted { $0.stableTabIdentifier < $1.stableTabIdentifier }
            return .choose(possible)
        }
        // Older records lack group metadata: even a single existing group
        // might have been a deliberately separate window. Ask instead of
        // silently joining it.
        let matches = candidates.filter { windows in
            windows.contains { (store.workspace(forTab: $0.stableTabIdentifier)?.id ?? WorkspaceStore.defaultWorkspaceId) == workspaceID }
        }
        if !matches.isEmpty {
            let anchors = matches.compactMap { windows in
                windows.first { (store.workspace(forTab: $0.stableTabIdentifier)?.id ?? WorkspaceStore.defaultWorkspaceId) == workspaceID }
            }.sorted { $0.stableTabIdentifier < $1.stableTabIdentifier }
            return .choose(anchors)
        }
        if candidates.isEmpty { return .newWindow }
        return .choose(candidates.compactMap(\.first).sorted { $0.stableTabIdentifier < $1.stableTabIdentifier })
    }
}
