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

    struct Row: Identifiable, Equatable {
        let item: SessionSidebarItem
        let workspaceColor: String?
        var id: String { item.id }
    }

    let kind: Kind
    let rows: [Row]
    var id: String { kind.rawValue }
    /// Sessions in the bucket, not their pane rows.
    var sessionCount: Int { rows.filter { !$0.item.isChild }.count }

    static func kind(of item: SessionSidebarItem) -> Kind {
        if item.needsAttention { return .needsYou }
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
                rows[parentKind, default: []].append(Row(item: item, workspaceColor: item.isChild ? nil : group.color))
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
