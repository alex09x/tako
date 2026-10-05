/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// Visible banner displayed on every pane participating in broadcast input (C8).
///
/// Indicates whether the pane is the active broadcaster (leader) or a recipient,
/// and provides an explicit control to terminate or leave broadcast mode.
public struct BroadcastInputBannerView: View {
    let paneId: UUID
    @ObservedObject var store: BroadcastInputStore = .shared

    public init(paneId: UUID) {
        self.paneId = paneId
    }

    public var body: some View {
        if let session = store.activeSession, session.selectedPaneIds.contains(paneId) {
            let isLeader = session.leaderPaneId == paneId
            let count = session.selectedPaneIds.count

            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isLeader ? Color(nsColor: Tako.Brand.ember) : .cyan)

                if isLeader {
                    Text("Broadcasting to \(count) panes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    Button("Stop Broadcast") {
                        store.endBroadcast()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(Color(nsColor: Tako.Brand.ember))
                    .help("Stop broadcasting input across panes")
                } else {
                    Text("Receiving Broadcast (\(count) panes)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Leave") {
                        store.paneClosed(paneId)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Remove this pane from the broadcast group")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isLeader ? Color(nsColor: Tako.Brand.ember).opacity(0.5) : Color.cyan.opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isLeader ? "Broadcasting input to \(count) panes" : "Receiving broadcast input")
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.15), value: isLeader)
        }
    }
}
