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

    // MARK: - Header (§5.1)

    func headerView(sessionCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("Sessions")
                .font(T.headerFont(size: 13))
                .foregroundColor(Color(nsColor: T.textActive))
                .accessibilityIdentifier("SessionSidebarHeader")

            Spacer()

            Text("\(sessionCount)")
                .font(Font(T.monoFont(size: 10, weight: .medium)))
                .foregroundColor(Color(nsColor: T.dim))

            Button(action: { store.createNewTab(in: targetWindow) }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(nsColor: T.dim))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SessionSidebarHeaderNewSession")
            .accessibilityLabel("New session")
            .help("New session")
        }
        .frame(height: 17)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Session") { store.createNewTab(in: targetWindow) }
            Divider()
            Toggle("Show Git Branch & Dirty Status", isOn: $store.optInGit)
            Toggle("Show Listening TCP Ports", isOn: $store.optInPorts)
        }
    }

    // MARK: - Footer (§5.8)

    func triggerNewSession() {
        store.createNewTab(in: targetWindow)
    }

    var footerView: some View {
        Button(action: triggerNewSession) {
            Text(newSessionHint)
                .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                .foregroundColor(Color(nsColor: T.dim))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SessionSidebarNewSession")
        .accessibilityLabel("New session")
    }

    var newSessionHint: String {
        guard let newSessionShortcut else { return "New session" }
        return "[\(KeybindRegistry.format(shortcut: newSessionShortcut))]  New session"
    }
}
