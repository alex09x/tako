/*
 * tako — Sidebar attention counters: waiting, error, unread done, one per pane
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

extension SessionSidebarStore {
    /// Every pane the sidebar lists (all its tab windows, every workspace),
    /// each counted once by its ID -- a session row and its pane rows never
    /// count the same pane twice. Muted panes do not count. Each counter is
    /// independent (`sidebar-count-*`); `status-show` never reaches here.
    func attentionCounts(for window: NSWindow?, preferences: DesktopPreferences,
                         workspaceStore: WorkspaceStore = .shared) -> SidebarAttentionCounts {
        var panes: [(id: UUID, kind: SidebarAttentionCounts.Kind)] = []
        var unread = Set<UUID>()
        for win in sidebarWindows(for: window, workspaceStore: workspaceStore).windows {
            for surface in surfaces(in: win) where !AttentionManager.shared.isMuted(surfaceId: surface.id) {
                panes.append((surface.id, Self.attentionKind(surface.crab.paneStatus)))
                if surface.crab.unread || NotificationStore.shared.unreadCount(for: surface.id) > 0 {
                    unread.insert(surface.id)
                }
            }
        }
        return SidebarAttentionCounts(panes: panes, unread: unread, preferences: preferences)
    }

    /// Waiting covers both a question and an approval request: in Tako they
    /// are one status and one colour.
    static func attentionKind(_ status: Tako.PaneStatus) -> SidebarAttentionCounts.Kind {
        switch status {
        case .waitingForInput, .needsApproval: .waiting
        case .error: .error
        case .done: .done
        default: .other
        }
    }
}

/// «waiting N  errors N  done N» (reference A01 `.sb-seg`): only the enabled
/// counters, a zero one dimmed. Accessibility: `SidebarAttentionCounts`
/// with value `waiting=N error=N done=N` (a disabled counter is left out).
struct SessionSidebarCountsLabel: View {
    let counts: SidebarAttentionCounts
    let preferences: DesktopPreferences
    private typealias T = Tako.LivingTokens

    var body: some View {
        HStack(spacing: 6) {
            if preferences.countsWaiting { part("waiting", counts.waiting, T.claw) }
            if preferences.countsErrors { part("errors", counts.errors, T.error) }
            if preferences.countsDone { part("done", counts.unreadDone, T.ok) }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("SidebarAttentionCounts")
        .accessibilityValue(Self.value(counts, preferences))
    }

    private func part(_ word: String, _ count: Int, _ color: NSColor) -> some View {
        Text("\(word) \(count)").foregroundColor(Color(nsColor: count > 0 ? color : T.dim))
    }

    static func value(_ counts: SidebarAttentionCounts, _ preferences: DesktopPreferences) -> String {
        var parts: [String] = []
        if preferences.countsWaiting { parts.append("waiting=\(counts.waiting)") }
        if preferences.countsErrors { parts.append("error=\(counts.errors)") }
        if preferences.countsDone { parts.append("done=\(counts.unreadDone)") }
        return parts.joined(separator: " ")
    }
}
