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
import TakoKit

extension AppDelegate {
    // MARK: - Workspace Actions

    @IBAction func nextWorkspace(_ sender: Any?) {
        WorkspaceStore.shared.nextWorkspace()
    }

    @IBAction func previousWorkspace(_ sender: Any?) {
        WorkspaceStore.shared.previousWorkspace()
    }

    @IBAction func newWorkspace(_ sender: Any?) {
        let ws = WorkspaceStore.shared.createWorkspace(name: "")
        WorkspaceStore.shared.switchWorkspace(to: ws.id)
    }

    @IBAction func showHelp(_ sender: Any) {
        guard let url = Brand.docsURL else { return }
        NSWorkspace.shared.open(url)
    }

    @IBAction func toggleSecureInput(_ sender: Any) {
        setSecureInput(.toggle)
    }

    @IBAction func toggleQuickTerminal(_ sender: Any) {
        quickController.toggle()
    }

    /// Toggles visibility of all Ghosty Terminal windows. When hidden, activates Tako as the frontmost application
    @IBAction func toggleVisibility(_ sender: Any) {
        // If we have focus, then we hide all windows.
        if NSApp.isActive {
            // Toggle visibility doesn't do anything if the focused window is native
            // fullscreen. This is only relevant if Tako is active.
            guard let keyWindow = NSApp.keyWindow,
                  !keyWindow.styleMask.contains(.fullScreen) else { return }

            NSApp.hide(nil)
            return
        }

        // If we're not active, we want to become active
        NSApp.activate(ignoringOtherApps: true)

        // Bring all windows to the front. Note: we don't use NSApp.unhide because
        // that will unhide ALL hidden windows. We want to only bring forward the
        // ones that we hid.
        hiddenState?.restore()
        hiddenState = nil
    }

    @IBAction func bringAllToFront(_ sender: Any) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        NSApplication.shared.arrangeInFront(sender)
    }

    @IBAction func undo(_ sender: Any?) {
        undoManager.undo()
    }

    @IBAction func redo(_ sender: Any?) {
        undoManager.redo()
    }

}
