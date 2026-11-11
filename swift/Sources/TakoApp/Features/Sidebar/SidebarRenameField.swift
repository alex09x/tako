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

/// A row's name in the sidebar: the name, or -- while this sidebar is
/// renaming the row (SidebarRenameEditor) -- a field holding the draft.
/// Double-clicking the name starts renaming where the row can be renamed.
struct SidebarRowTitle: View {
    let item: SessionSidebarItem
    let targetWindow: NSWindow?
    let font: NSFont
    let color: Color
    @ObservedObject private var editor = SidebarRenameEditor.shared

    var body: some View {
        if editor.isEditing(item.id, in: targetWindow) {
            SidebarRenameField(item: item, targetWindow: targetWindow, font: font, draft: editor.draft)
        } else {
            Text(item.title)
                .font(Font(font))
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    editor.begin(item, in: targetWindow, store: .shared)
                })
        }
    }
}

/// Return keeps the name, Esc or clicking away leaves the old one; an empty
/// name hands back to the automatic one. A name that cannot be saved stays
/// in the field, the reason under it.
private struct SidebarRenameField: View {
    let item: SessionSidebarItem
    let targetWindow: NSWindow?
    let font: NSFont
    @ObservedObject var draft: SidebarRenameEditor.Draft
    @State private var mount = 0
    @FocusState private var focused: Bool
    private var editor: SidebarRenameEditor { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(item.isChild ? "Terminal name" : "Session name", text: $draft.text)
                .textFieldStyle(.plain)
                .font(Font(font))
                .foregroundColor(Color(nsColor: Tako.LivingTokens.textActive))
                .focused($focused)
                .onSubmit { editor.commit(item, in: targetWindow, store: .shared) }
                .onExitCommand { editor.cancel() }
                .accessibilityIdentifier("SidebarRenameField")
            if let error = draft.error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(nsColor: Tako.LivingTokens.error))
                    .lineLimit(2)
                    .accessibilityIdentifier("SidebarRenameError")
            }
        }
        .onAppear {
            mount = editor.mounted()
            focused = true
        }
        .onChange(of: focused) { _, now in if !now { editor.blurred(mount: mount) } }
    }
}
