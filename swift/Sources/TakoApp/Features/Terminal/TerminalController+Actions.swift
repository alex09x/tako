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
        let visible = tabGroup.visibleWindows
        guard let currentIndex = visible.firstIndex(of: window) else { return }

        let tabsToClose = visible.enumerated().filter { $0.offset > currentIndex }
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

        // When closing the last window with quit-after-last-window-closed enabled,
        // closing the window means closing the application. Routing through NSApp.terminate
        // allows persistent sessions to be safely detached and window layout to be saved
        // so everything restores on next launch, while cleanly terminating the process.
        let otherTerminalGroups = Tako.CustomTabGroup.allGroups.filter {
            $0 !== tabGroup && $0.windows.contains(where: { $0.windowController is TerminalController })
        }
        let isLastWindow = controllers.count >= TerminalController.all.count || otherTerminalGroups.isEmpty
        if isLastWindow && tako.config.shouldQuitAfterLastWindowClosed {
            NSApp.terminate(sender)
            return
        }

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

    // MARK: - Tab Selection & Reordering

    func gotoTab(at index: Int) {
        guard let window = self.window else { return }
        let group = Tako.CustomTabGroup.group(for: window)
        let visible = group.visibleWindows
        guard !visible.isEmpty else { return }
        if index == 8 {
            if let last = visible.last { group.select(last) }
        } else if index >= 0 && index < visible.count {
            group.select(visible[index])
        }
    }

    @IBAction func gotoTab1(_ sender: Any?) { gotoTab(at: 0) }
    @IBAction func gotoTab2(_ sender: Any?) { gotoTab(at: 1) }
    @IBAction func gotoTab3(_ sender: Any?) { gotoTab(at: 2) }
    @IBAction func gotoTab4(_ sender: Any?) { gotoTab(at: 3) }
    @IBAction func gotoTab5(_ sender: Any?) { gotoTab(at: 4) }
    @IBAction func gotoTab6(_ sender: Any?) { gotoTab(at: 5) }
    @IBAction func gotoTab7(_ sender: Any?) { gotoTab(at: 6) }
    @IBAction func gotoTab8(_ sender: Any?) { gotoTab(at: 7) }
    @IBAction func gotoTab9(_ sender: Any?) { gotoTab(at: 8) }

    @IBAction func previousTab(_ sender: Any?) {
        guard let window = self.window else { return }
        let group = Tako.CustomTabGroup.group(for: window)
        let visible = group.visibleWindows
        guard visible.count > 1, let current = group.selectedWindow, let idx = visible.firstIndex(of: current) else { return }
        let prevIdx = idx == 0 ? visible.count - 1 : idx - 1
        group.select(visible[prevIdx])
    }

    @IBAction func nextTab(_ sender: Any?) {
        guard let window = self.window else { return }
        let group = Tako.CustomTabGroup.group(for: window)
        let visible = group.visibleWindows
        guard visible.count > 1, let current = group.selectedWindow, let idx = visible.firstIndex(of: current) else { return }
        let nextIdx = idx == visible.count - 1 ? 0 : idx + 1
        group.select(visible[nextIdx])
    }

    @IBAction func moveTabLeft(_ sender: Any?) {
        guard let window = self.window else { return }
        let group = Tako.CustomTabGroup.group(for: window)
        guard let selectedWindow = group.selectedWindow else { return }
        let visible = group.visibleWindows
        guard let idx = visible.firstIndex(of: selectedWindow), idx > 0 else { return }
        Tako.CustomTabGroup.move(selectedWindow, to: idx - 1, in: group)
        LayoutRecorder.record()
    }

    @IBAction func moveTabRight(_ sender: Any?) {
        guard let window = self.window else { return }
        let group = Tako.CustomTabGroup.group(for: window)
        guard let selectedWindow = group.selectedWindow else { return }
        let visible = group.visibleWindows
        guard let idx = visible.firstIndex(of: selectedWindow), idx < visible.count - 1 else { return }
        Tako.CustomTabGroup.move(selectedWindow, to: idx + 1, in: group)
        LayoutRecorder.record()
    }

}
