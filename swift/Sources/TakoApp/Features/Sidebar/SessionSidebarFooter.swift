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
        Text(newSessionHint)
            .font(Font(T.monoFont(size: 10.5, weight: .regular)))
            .foregroundColor(Color(nsColor: T.dim))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }

    var newSessionHint: String {
        guard let newSessionShortcut else { return "New session" }
        return "[\(KeybindRegistry.format(shortcut: newSessionShortcut))]  New session"
    }
}
