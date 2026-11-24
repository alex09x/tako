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

/// Keeps the sidebar's arrow-key cursor on a row, not on a position.
///
/// Grouped by status the rows reorder by themselves: a session that starts
/// running leaves Needs you. The cursor (and Return) stays on the row it was
/// on; if that row is gone it stays at the same place, within the list. The
/// cursor goes to the active tab only when the active tab changes, not when
/// it merely moves in the list.
struct SidebarCursorKeeper: ViewModifier {
    /// The rows' ids in the order shown.
    let ids: [String]
    let activeId: String?
    let enabled: Bool
    @Binding var selectedIndex: Int
    let followActive: () -> Void
    @State private var cursorId: String?

    private func remember(_ index: Int, in list: [String]) {
        cursorId = list.indices.contains(index) ? list[index] : nil
    }

    func body(content: Content) -> some View {
        content
            .onAppear { remember(selectedIndex, in: ids) }
            .onChange(of: selectedIndex) { _, index in remember(index, in: ids) }
            .onChange(of: ids) { _, now in
                guard enabled else { return }
                if let cursorId, let index = now.firstIndex(of: cursorId) {
                    if index != selectedIndex { selectedIndex = index }
                } else {
                    // The row is gone: the cursor stays where it was, within the list.
                    if !now.isEmpty, selectedIndex >= now.count { selectedIndex = now.count - 1 }
                    remember(selectedIndex, in: now)
                }
            }
            .onChange(of: activeId) { _, _ in
                guard enabled else { return }
                followActive()
            }
    }
}
