/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

/// Renaming a terminal in the sidebar, in place: Return keeps the name, Esc
/// leaves it, an empty name and «Use Automatic Name» give the automatic one
/// back. The name is the pane's own (PaneTitleStore), the one its card shows.
@Suite(.serialized) @MainActor
struct SidebarRenameTests {
    private func pane(_ surface: UUID) -> SessionSidebarItem {
        SessionSidebarItem(id: "tab-pane-\(surface)", surfaceId: surface, index: 0, isSelected: false, title: "fish",
                           isChild: true, indentationLevel: 2, tabId: "tab")
    }

    @Test func aTerminalIsRenamedInPlaceAndCanGetItsAutomaticNameBack() {
        let store = SessionSidebarStore.shared, id = UUID(), row = pane(id)
        defer { PaneTitleStore.shared.setTitle(nil, for: id); store.cancelRename() }

        store.beginRename(row)
        #expect(store.renamingRowId == row.id)
        store.cancelRename()
        #expect(store.renamingRowId == nil && store.ownName(of: row, around: nil) == nil, "Esc keeps the old name")

        store.beginRename(row)
        store.commitRename(row, to: "  build logs  ", around: nil)
        #expect(store.renamingRowId == nil)
        #expect(store.ownName(of: row, around: nil) == "build logs")
        #expect(PaneTitleStore.shared.title(for: id) == "build logs", "the card header shows the same name")

        store.commitRename(row, to: "   ", around: nil)
        #expect(store.ownName(of: row, around: nil) == nil, "an empty name is the automatic one")

        store.commitRename(row, to: "deploy", around: nil)
        store.useAutomaticName(row, around: nil)
        #expect(store.ownName(of: row, around: nil) == nil)
    }
}
