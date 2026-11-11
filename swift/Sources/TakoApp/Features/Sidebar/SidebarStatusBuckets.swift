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
import SwiftUI

/// The sidebar grouped by status (`sidebar-group = status`): what needs you
/// first, then what runs, what finished, and the rest. A session keeps its
/// pane rows under it; its workspace becomes a coloured dot on the row.
struct SidebarStatusBucket: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case needsYou = "Needs you", running = "Running", done = "Done", quiet = "Quiet"
    }

    /// Which workspace a session belongs to, shown on its row in place of
    /// the heading: its name for the tooltip and VoiceOver, and its colour,
    /// nil when the workspace takes the automatic one.
    struct WorkspaceBadge: Equatable {
        let id: UUID
        let name: String
        let color: String?
    }

    struct Row: Identifiable, Equatable {
        let item: SessionSidebarItem
        /// The session's workspace; nil on a pane row.
        let workspace: WorkspaceBadge?
        var id: String { item.id }
    }

    let kind: Kind
    let rows: [Row]
    var id: String { kind.rawValue }
    /// Sessions in the bucket, not their pane rows.
    var sessionCount: Int { rows.filter { !$0.item.isChild }.count }

    /// The row's own state, as its ring shows it: an idle row someone has
    /// to look at is already waiting there (`surfaceState`). An unread done
    /// or running row stays Done or Running.
    static func kind(of item: SessionSidebarItem) -> Kind {
        return switch item.surfaceState {
        case .waiting, .failed: .needsYou
        case .working, .progress, .live: .running
        case .done: .done
        case .idle, .offline: .quiet
        }
    }

    /// The workspace groups' rows, regrouped; empty buckets are left out.
    static func buckets(from groups: [SessionSidebarWorkspaceGroup]) -> [SidebarStatusBucket] {
        var rows: [Kind: [Row]] = [:]
        for group in groups {
            var parentKind: Kind = .quiet
            for item in group.items {
                if !item.isChild { parentKind = kind(of: item) }
                let badge = item.isChild ? nil : WorkspaceBadge(id: group.id, name: group.name, color: group.color)
                rows[parentKind, default: []].append(Row(item: item, workspace: badge))
            }
        }
        return Kind.allCases.compactMap { kind in rows[kind].map { SidebarStatusBucket(kind: kind, rows: $0) } }
    }
}

/// A bucket's heading: its name and how many sessions it holds.
struct SidebarStatusBucketHeader: View {
    let bucket: SidebarStatusBucket
    typealias T = Tako.LivingTokens

    var body: some View {
        HStack(spacing: 8) {
            Text(bucket.kind.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(nsColor: bucket.kind == .needsYou ? T.claw : T.textInactive))
            Spacer(minLength: 0)
            Text("\(bucket.sessionCount)")
                .font(Font(T.monoFont(size: 10.5, weight: .medium)))
                .foregroundColor(Color(nsColor: T.dim))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("SidebarStatusBucket-\(bucket.kind)")
    }
}
