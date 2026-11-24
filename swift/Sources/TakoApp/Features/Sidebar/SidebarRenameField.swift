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

/// A row's name in the sidebar: the name, or -- while this sidebar is
/// renaming the row (SidebarRenameEditor) -- a field holding the draft.
/// Double-clicking the row starts renaming where the row can be renamed
/// (`renameIfDoubleClick`, asked by the row's own click handler).
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
        }
    }

    /// Clicks on sidebar rows, for telling a double click on one row apart.
    @MainActor static var clicks = SidebarDoubleClick()

    /// The second click of a double click on this same row, in the same
    /// window, starts renaming it; the row's own click handler asks after
    /// selecting. No gesture of its own on the name: a `TapGesture(count: 2)`
    /// there made SwiftUI hold every single click on the name for the
    /// double-click interval (~0.5 s) before the row switched tabs, and a
    /// single tap there took the click from the row.
    static func renameIfDoubleClick(_ item: SessionSidebarItem, in targetWindow: NSWindow?,
                                    event: NSEvent? = NSApp.currentEvent,
                                    interval: TimeInterval = NSEvent.doubleClickInterval) {
        guard let (click, count) = SidebarDoubleClick.click(on: item.id, in: targetWindow, event: event),
              clicks.isSecond(click, clickCount: count, interval: interval) else { return }
        SidebarRenameEditor.shared.begin(item, in: targetWindow, store: .shared)
    }
}

/// Why the name being typed for this row could not be kept: a line of its
/// own under the row's title band, which grows the row only while it shows.
struct SidebarRenameErrorLine: View {
    let item: SessionSidebarItem
    let targetWindow: NSWindow?
    @ObservedObject private var editor = SidebarRenameEditor.shared

    var body: some View {
        if editor.isEditing(item.id, in: targetWindow) {
            Reason(draft: editor.draft)
        }
    }

    private struct Reason: View {
        @ObservedObject var draft: SidebarRenameEditor.Draft
        var body: some View {
            if let error = draft.error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(nsColor: Tako.LivingTokens.error))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("SidebarRenameError")
            }
        }
    }
}

/// Return keeps the name, Esc or clicking away leaves the old one; an empty
/// name hands back to the automatic one. A name that cannot be saved stays
/// in the field; SidebarRenameErrorLine says why, under the title band.
private struct SidebarRenameField: View {
    let item: SessionSidebarItem
    let targetWindow: NSWindow?
    let font: NSFont
    @ObservedObject var draft: SidebarRenameEditor.Draft
    @State private var mount = 0
    @FocusState private var focused: Bool
    private var editor: SidebarRenameEditor { .shared }

    var body: some View {
        TextField(item.isChild ? "Terminal name" : "Session name", text: $draft.text)
            .textFieldStyle(.plain)
            .font(Font(font))
            .foregroundColor(Color(nsColor: Tako.LivingTokens.textActive))
            .focused($focused)
            .onSubmit { editor.commit(item, in: targetWindow, store: .shared) }
            .onExitCommand { editor.cancel() }
            .accessibilityIdentifier("SidebarRenameField")
        .onAppear {
            mount = editor.mounted()
            focused = true
            // A double-click opens the field inside its own click: once the
            // click is done, the window takes the focus back to itself. Ask
            // again after it, so the keys come here.
            DispatchQueue.main.async { if editor.isEditing(item.id, in: targetWindow) { focused = true } }
        }
        .onChange(of: focused) { _, now in
            if now { editor.focused(mount: mount) } else { editor.blurred(mount: mount) }
        }
    }
}
