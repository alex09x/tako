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
import TakoKit

extension SessionSidebarView {
    /// Puts the arrow-key cursor on the active tab's row.
    func followActiveTab() {
        showsArrowCursor = false
        if let activeIndex = SessionSidebarSelection.activeIndex(in: items) {
            selectedIndex = activeIndex
        }
    }

    func jumpToNextWaiting() {
        let allItems = items
        guard !allItems.isEmpty else { return }
        let start = max(0, selectedIndex)
        for offset in 1...allItems.count {
            let idx = (start + offset) % allItems.count
            let candidate = allItems[idx]
            if candidate.surfaceState == .waiting || candidate.needsAttention {
                selectedIndex = idx
                store.selectTab(item: candidate, in: targetWindow, workspaceStore: workspaceStore)
                return
            }
        }
    }

    // MARK: - Footer (§5.8)

    var footerView: some View {
        HStack(spacing: 8) {
            Button(action: {
                if let win = targetWindow, let surface = store.surfaces(in: win).first {
                    NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: surface)
                }
            }) {
                Text("+ New session").font(Font(T.monoFont(size: 10.5, weight: .regular))).foregroundColor(Color(nsColor: T.dim))
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: jumpToNextWaiting) {
                (Text("⌥⏎").font(.custom("Menlo-Regular", fixedSize: 10.5)) + Text(" next waiting").font(Font(T.monoFont(size: 10.5, weight: .regular))))
                    .foregroundColor(Color(nsColor: T.dim))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
