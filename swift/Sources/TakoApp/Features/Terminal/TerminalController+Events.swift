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
    func setupTerminalNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Tako.Notification.takoToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .takoMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Tako.Notification.takoGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .takoCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseOtherTabs),
            name: .takoCloseOtherTabs,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTabsOnTheRight),
            name: .takoCloseTabsOnTheRight,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onResetWindowSize),
            name: .takoResetWindowSize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(takoConfigDidChange(_:)),
            name: .takoConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseWindow),
            name: .takoCloseWindow,
            object: nil
        )
    }

    // MARK: - Notifications

    @objc func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the move action
        guard let action = notification.userInfo?[Notification.Name.TakoMoveTabKey] as? Tako.Action.MoveTab else { return }
        guard action.amount != 0 else { return }

        let group = Tako.CustomTabGroup.group(for: window)
        guard let selectedWindow = group.selectedWindow else { return }
        let tabbedWindows = group.windows
        guard tabbedWindows.count > 0 else { return }
        guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

        // Determine the final index we want to insert our tab
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = selectedIndex - min(selectedIndex, -action.amount)
        } else {
            let remaining: Int = tabbedWindows.count - 1 - selectedIndex
            finalIndex = selectedIndex + min(remaining, action.amount)
        }

        // If our index is the same we do nothing
        guard finalIndex != selectedIndex else { return }

        Tako.CustomTabGroup.move(selectedWindow, to: finalIndex, in: group)
    }

    @objc func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the tab index from the notification
        guard let tabEnumAny = notification.userInfo?[Tako.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? tako_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        let tabGroup = Tako.CustomTabGroup.group(for: window)
        let tabbedWindows = tabGroup.windows

        // This will be the index we want to actual go to
        let finalIndex: Int

        // An index that is invalid is used to signal some special values.
        if tabIndex <= 0 {
            guard let selectedWindow = tabGroup.selectedWindow else { return }
            guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

            if tabIndex == TAKO_GOTO_TAB_PREVIOUS.rawValue {
                if selectedIndex == 0 {
                    finalIndex = tabbedWindows.count - 1
                } else {
                    finalIndex = selectedIndex - 1
                }
            } else if tabIndex == TAKO_GOTO_TAB_NEXT.rawValue {
                if selectedIndex == tabbedWindows.count - 1 {
                    finalIndex = 0
                } else {
                    finalIndex = selectedIndex + 1
                }
            } else if tabIndex == TAKO_GOTO_TAB_LAST.rawValue {
                finalIndex = tabbedWindows.count - 1
            } else {
                return
            }
        } else {
            // The configured value is 1-indexed.
            guard tabIndex >= 1 else { return }

            // If our index is outside our boundary then we use the max
            finalIndex = min(Int(tabIndex - 1), tabbedWindows.count - 1)
        }

        guard finalIndex >= 0 else { return }
        tabGroup.select(tabbedWindows[finalIndex])
    }

    @objc func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherTabs(self)
    }

    @objc func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTabsOnTheRight(self)
    }

    @objc func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the fullscreen mode we want to toggle
        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Tako.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Tako.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }
}
