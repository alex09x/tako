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

    /// ⌘K: the search field is always shown (reference A01); this focuses it.
    func toggleSearchBar() {
        isSearchExpanded = true
        searchFocusToken &+= 1
    }

    /// Escape in the field: the query and the needs-you filter are cleared,
    /// the list takes the keys back. The field itself stays.
    func collapseSearchAndClearFilter() {
        if let win = targetWindow,
           let editor = win.firstResponder as? NSTextView,
           editor.delegate is SidebarSearchNSTextField {
            _ = win.makeFirstResponder(nil as NSResponder?)
        }
        if !filterText.isEmpty {
            store.setFilterText("", for: targetWindow)
        }
        if filterNeedsAttention {
            store.setFilterNeedsAttention(false, for: targetWindow)
        }
        isSearchExpanded = false
        isSearchFocused = false
        isListFocused = true
    }

    // MARK: - Footer (§5.8)

    func triggerNewSession() {
        store.createNewTab(in: targetWindow)
    }

    var footerView: some View {
        ZStack(alignment: .leading) {
            Text(newSessionHint)
                .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                .foregroundColor(Color(nsColor: T.dim))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            FloatingActionButtonOverlay(
                identifier: "SessionSidebarNewSession",
                label: "New session",
                value: "",
                helpText: "New session",
                onHoverChange: { _ in },
                action: triggerNewSession
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var newSessionHint: String {
        guard let newSessionShortcut else { return "New session" }
        return "[\(KeybindRegistry.format(shortcut: newSessionShortcut))]  New session"
    }
}
