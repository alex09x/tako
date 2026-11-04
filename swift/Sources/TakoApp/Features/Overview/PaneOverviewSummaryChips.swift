// tako — Terminal emulator
// Copyright (c) 2026 Alexander Panasenko
//
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import SwiftUI

struct PaneOverviewSummaryChips: View {
    @ObservedObject var store: PaneOverviewStore
    let waitingCount: Int
    let workingCount: Int
    let toggleStatusFilter: (PaneOverviewStore.StatusFilter) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if waitingCount > 0 {
                Button(action: { toggleStatusFilter(.needsYou) }) {
                    LivingStatusChipView(status: .needsApproval, customLabel: "\(waitingCount) need you")
                }
                .buttonStyle(.plain)
            }
            if workingCount > 0 {
                Button(action: { toggleStatusFilter(.working) }) {
                    LivingStatusChipView(status: .working, customLabel: "\(workingCount) working")
                }
                .buttonStyle(.plain)
            }
            Button(action: { store.statusFilter = nil; store.filterText = "" }) {
                LivingStatusChipView(status: .idle, customLabel: store.paneCountLabel)
            }
            .buttonStyle(.plain)
        }
    }
}
