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

/// What a row's name is and where it is kept, for renaming in place
/// (SidebarRenameEditor). A session's name is its tab's title override; a
/// terminal's is its own pane name (PaneTitleStore), the one its card header
/// shows too. A row that is neither -- an agent listed under a session with no
/// terminal of its own -- cannot be renamed: there is no name it would show.
extension SessionSidebarStore {
    /// Whether this row has a name the sidebar would show if it were renamed.
    func canRename(_ item: SessionSidebarItem, around window: NSWindow?) -> Bool {
        guard let target = sidebarWindow(tabId: item.tabId, around: window) else { return false }
        if !item.isChild { return controller(of: target) != nil }
        guard let id = item.surfaceId else { return false }
        return surfaces(in: target).contains { $0.id == id }
    }

    /// The name someone gave this row, if any.
    func ownName(of item: SessionSidebarItem, around window: NSWindow?, paneTitles: PaneTitleStore = .shared) -> String? {
        if item.isChild { return item.surfaceId.flatMap { paneTitles.title(for: $0) } }
        return sidebarWindow(tabId: item.tabId, around: window).flatMap(controller(of:))?.titleOverride
    }

    /// Keeps `name` as the row's own; empty gives the automatic name back.
    /// Returns why it was not kept, and then nothing changed.
    func setName(_ name: String, of item: SessionSidebarItem, around window: NSWindow?,
                 paneTitles: PaneTitleStore = .shared) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canRename(item, around: window) else { return "This row has no name of its own to change." }
        defer { objectWillChange.send() }
        if item.isChild {
            guard let id = item.surfaceId else { return "This terminal is gone." }
            return paneTitles.setTitle(trimmed.isEmpty ? nil : trimmed, for: id)?.localizedDescription
        }
        guard let controller = sidebarWindow(tabId: item.tabId, around: window).flatMap(controller(of:)) else {
            return "This session is gone."
        }
        controller.titleOverride = trimmed.isEmpty ? nil : trimmed
        return nil
    }

    private func controller(of window: NSWindow) -> BaseTerminalController? {
        (window.windowController as? BaseTerminalController) ?? (window.delegate as? BaseTerminalController)
    }
}
