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
    // MARK: First Responder

    // `Tako.App.newWindow(surface:)`/`newTab(surface:)` were unimplemented
    // stubs -- routing through them here silently did nothing. Because this
    // controller sits earlier in the responder chain than `AppDelegate`,
    // *this* copy of `newTab(_:)`/`newWindow(_:)` is the one Cmd+T/Cmd+N and
    // the matching menu items actually reach, not `AppDelegate`'s (which
    // already called the right thing, but is shadowed while any terminal
    // window is key). Call the same static constructors AppleScript's
    // working `new tab`/`new window` commands use.
    @IBAction func newWindow(_ sender: Any?) {
        _ = TerminalController.newWindow(tako, withParent: window)
    }

    @IBAction func newTab(_ sender: Any?) {
        _ = TerminalController.newTab(tako, from: window)
    }

    @IBAction func closeTab(_ sender: Any?) {
        guard let window = window else { return }
        guard Tako.CustomTabGroup.group(for: window).windows.count > 1 else {
            closeWindow(sender)
            return
        }

        guard surfaceTree.contains(where: { $0.needsConfirmClose }) else {
            closeTabImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately()
        }
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        guard let window = window else { return }
        let tabGroup = Tako.CustomTabGroup.group(for: window)

        // If we only have one window then we have no other tabs to close
        guard tabGroup.windows.count > 1 else { return }

        // Check if we have to confirm close.
        guard tabGroup.windows.contains(where: { window in
            // Ignore ourself
            if window == self.window { return false }

            // Ignore non-terminals
            guard let controller = window.windowController as? TerminalController else {
                return false
            }

            // Check if any surfaces require confirmation
            return controller.surfaceTree.contains(where: { $0.needsConfirmClose })
        }) else {
            self.closeOtherTabsImmediately()
            return
        }

        confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately()
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        guard let window = window else { return }
        let tabGroup = Tako.CustomTabGroup.group(for: window)
        guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return }

        let tabsToClose = tabGroup.windows.enumerated().filter { $0.offset > currentIndex }
        guard !tabsToClose.isEmpty else { return }

        let needsConfirm = tabsToClose.contains { (_, candidate) in
            guard let controller = candidate.windowController as? TerminalController else {
                return false
            }

            return controller.surfaceTree.contains(where: { $0.needsConfirmClose })
        }

        if !needsConfirm {
            self.closeTabsOnTheRightImmediately()
            return
        }

        confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let window, let defaultSize else { return }
        defaultSize.apply(to: window)
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        guard let window = window else { return }

        // We need to check all the windows in our tab group for confirmation
        // if we're closing the window.
        let tabGroup = Tako.CustomTabGroup.group(for: window)
        let windows: [NSWindow] = tabGroup.windows
        let controllers = windows.compactMap { $0.windowController as? TerminalController }
        let needsConfirm = controllers.contains { $0.surfaceTree.contains(where: { $0.needsConfirmClose }) }
        guard needsConfirm else {
            closeWindowImmediately()
            return
        }

        // We call confirmClose on the currently active / visible controller so the alert is
        // attached to the window the user is actually looking at and interacting with.
        let activeController = (tabGroup.selectedWindow?.windowController as? TerminalController) ?? self
        activeController.confirmClose(
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated.",
        ) {
            self.closeWindowImmediately()
        }
    }

    // `Tako.App.toggleFullscreen(surface:)` was an unimplemented stub --
    // this controller's own `toggleFullscreen(mode:)` (used directly by
    // `newWindow` to inherit fullscreen state) is the real implementation.
    @IBAction func toggleTakoFullScreen(_ sender: Any?) {
        toggleFullscreen(mode: .native)
    }

}
