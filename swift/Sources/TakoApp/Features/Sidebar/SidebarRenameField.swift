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

/// A row's name in the sidebar: the name, or -- while the row is being
/// renamed -- a field holding it. Double-clicking the name starts renaming.
/// Return keeps the new name, Esc (or clicking away) leaves the old one; an
/// empty name hands back to the automatic one.
struct SidebarRowTitle: View {
    let item: SessionSidebarItem
    let targetWindow: NSWindow?
    let font: NSFont
    let color: Color
    @ObservedObject var store = SessionSidebarStore.shared

    var body: some View {
        if store.renamingRowId == item.id {
            SidebarRenameField(item: item, targetWindow: targetWindow, font: font)
        } else {
            Text(item.title)
                .font(Font(font))
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .simultaneousGesture(TapGesture(count: 2).onEnded { store.beginRename(item) })
        }
    }
}

private struct SidebarRenameField: View {
    let item: SessionSidebarItem
    let targetWindow: NSWindow?
    let font: NSFont
    @ObservedObject var store = SessionSidebarStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(item.isChild ? "Terminal name" : "Session name", text: $text)
            .textFieldStyle(.plain)
            .font(Font(font))
            .foregroundColor(Color(nsColor: Tako.LivingTokens.textActive))
            .focused($focused)
            .onAppear {
                text = store.ownName(of: item, around: targetWindow) ?? item.title
                focused = true
            }
            .onSubmit { store.commitRename(item, to: text, around: targetWindow) }
            .onExitCommand { store.cancelRename() }
            .onChange(of: focused) { _, now in if !now, store.renamingRowId == item.id { store.cancelRename() } }
            .accessibilityIdentifier("SidebarRenameField")
    }
}
