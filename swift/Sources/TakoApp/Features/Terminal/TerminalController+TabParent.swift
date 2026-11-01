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

extension TerminalController {
    /// An implicit new-tab action must not attach to a hidden window in a
    /// different workspace when no main window has been established yet.
    static var preferredTabParent: TerminalController? {
        let store = WorkspaceStore.shared
        let candidates = all.filter { controller in
            guard let window = controller.window, !Tako.CustomTabGroup.isClosed(window) else { return false }
            let workspace = store.workspace(forTab: window.stableTabIdentifier)?.id ?? WorkspaceStore.defaultWorkspaceId
            return workspace == store.activeWorkspaceId
        }
        return candidates.first { $0.window?.isMainWindow == true }
            ?? candidates.first { $0 === lastMain }
            ?? candidates.last
    }
}
