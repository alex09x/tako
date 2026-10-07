/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Cocoa
import SwiftUI
import TakoKit

extension TerminalController {
    func closeTabImmediately(registerRedo: Bool = true) {
        guard let window = window else { return }
        let tabGroup = Tako.CustomTabGroup.group(for: window)
        guard tabGroup.windows.count > 1 else {
            closeWindowImmediately()
            return
        }

        cancelPendingInitialPresentation()

        // Undo
        if let undoManager, let undoState {
            // Register undo action to restore the tab
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: tako,
                expiresAfter: undoExpiration
            ) { tako in
                let newController = TerminalController(tako, with: undoState)

                if registerRedo {
                    undoManager.registerUndo(
                        withTarget: newController,
                        expiresAfter: newController.undoExpiration
                    ) { target in
                        target.closeTabImmediately()
                    }
                }
            }
        }

        window.close()
    }

    func closeOtherTabsImmediately() {
        guard let window = window else { return }
        let tabGroup = Tako.CustomTabGroup.group(for: window)
        guard tabGroup.windows.count > 1 else { return }

        // Start an undo grouping
        if let undoManager {
            undoManager.beginUndoGrouping()
        }
        defer {
            undoManager?.endUndoGrouping()
        }

        // Iterate through all tabs except the current one.
        for window in tabGroup.windows where window != self.window {
            // We ignore any non-terminal tabs. They don't currently exist and we can't
            // properly undo them anyways so I'd rather ignore them and get a bug report
            // later if and when we introduce non-terminal tabs.
            if let controller = window.windowController as? TerminalController {
                // We must not register a redo, because it messes with our own redo
                // that we register later.
                controller.closeTabImmediately(registerRedo: false)
            }
        }

        if let undoManager {
            undoManager.setActionName("Close Other Tabs")

            // We need to register an undo that refocuses this window. Otherwise, the
            // undo operation above for each tab will steal focus.
            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    // select(), not makeKeyAndOrderFront directly: native tabbing
                    // is disallowed, so nothing else hides whichever sibling tab
                    // was restored alongside this one.
                    if let window = target.window {
                        Tako.CustomTabGroup.group(for: window).select(window)
                    }
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeOtherTabsImmediately()
                }
            }
        }
    }

    func closeTabsOnTheRightImmediately() {
        guard let window = window else { return }
        let tabGroup = Tako.CustomTabGroup.group(for: window)
        let visible = tabGroup.visibleWindows
        guard let currentIndex = visible.firstIndex(of: window) else { return }

        let tabsToClose = visible.enumerated().filter { $0.offset > currentIndex }
        guard !tabsToClose.isEmpty else { return }

        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
        }

        for (_, candidate) in tabsToClose {
            if let controller = candidate.windowController as? TerminalController {
                controller.closeTabImmediately(registerRedo: false)
            }
        }

        if let undoManager {
            undoManager.setActionName("Close Tabs to the Right")

            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    // select(), not makeKeyAndOrderFront directly: native tabbing
                    // is disallowed, so nothing else hides whichever sibling tab
                    // was restored alongside this one.
                    if let window = target.window {
                        Tako.CustomTabGroup.group(for: window).select(window)
                    }
                }

                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeTabsOnTheRightImmediately()
                }
            }
        }
    }

    /// Closes the current window (including any other tabs) immediately and without
    /// confirmation. This will setup proper undo state so the action can be undone.
}
