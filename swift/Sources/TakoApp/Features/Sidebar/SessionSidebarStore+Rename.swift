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

/// Renaming in the list itself: double-click a name, F2, or «Rename…» in a
/// row's menu turns the name into a field; Return keeps it, Esc leaves it as
/// it was, and an empty name goes back to the automatic one (SessionNaming).
/// A session's name is its tab's title override; a terminal's is its own
/// pane name (PaneTitleStore), the one its card header shows too.
extension SessionSidebarStore {
    func beginRename(_ item: SessionSidebarItem) {
        renamingRowId = item.id
    }

    func cancelRename() {
        renamingRowId = nil
    }

    /// The name someone gave this row, if any.
    func ownName(of item: SessionSidebarItem, around window: NSWindow?) -> String? {
        if item.isChild { return item.surfaceId.flatMap { PaneTitleStore.shared.title(for: $0) } }
        return controller(for: item, around: window)?.titleOverride
    }

    func commitRename(_ item: SessionSidebarItem, to text: String, around window: NSWindow?) {
        defer { renamingRowId = nil; objectWillChange.send() }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.isChild {
            guard let id = item.surfaceId else { return }
            PaneTitleStore.shared.setTitle(name.isEmpty ? nil : name, for: id)
        } else {
            controller(for: item, around: window)?.titleOverride = name.isEmpty ? nil : name
        }
    }

    /// «Use Automatic Name»: the name someone gave goes; the automatic one comes back.
    func useAutomaticName(_ item: SessionSidebarItem, around window: NSWindow?) {
        commitRename(item, to: "", around: window)
    }

    private func controller(for item: SessionSidebarItem, around window: NSWindow?) -> BaseTerminalController? {
        guard let target = sidebarWindow(tabId: item.tabId, around: window) else { return nil }
        return (target.windowController as? BaseTerminalController) ?? (target.delegate as? BaseTerminalController)
    }
}
