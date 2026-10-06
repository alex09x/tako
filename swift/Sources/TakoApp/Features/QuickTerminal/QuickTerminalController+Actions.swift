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

extension QuickTerminalController {
    func showNoNewTabAlert() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Cannot Create New Tab"
        alert.informativeText = "Tabs aren't supported in the Quick Terminal."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
    // MARK: First Responder
    @IBAction func newTab(_ sender: Any?) {
        showNoNewTabAlert()
    }

    @IBAction func toggleTakoFullScreen(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        tako.toggleFullscreen(surface: surface)
    }

    // MARK: Notifications

    @objc func applicationWillTerminate(_ notification: Notification) {
        // If the application is going to terminate we want to make sure we
        // restore any global dock state. I think deinit should be called which
        // would call this anyways but I can't be sure so I will do this too.
        hiddenDock = nil
    }

    @objc func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        onToggleFullscreen()
    }

    func onToggleFullscreen() {
        // We ignore the configured fullscreen style and always use non-native
        // because the way the quick terminal works doesn't support native.
        let mode: FullscreenMode
        if NSApp.isFrontmost {
            // If we're frontmost and we have a notch then we keep padding
            // so all lines of the terminal are visible.
            if window?.screen?.hasNotch ?? false {
                mode = .nonNativePaddedNotch
            } else {
                mode = .nonNative
            }
        } else {
            // An additional detail is that if the is NOT frontmost, then our
            // NSApp.presentationOptions will not take effect so we must always
            // do the visible menu mode since we can't get rid of the menu.
            mode = .nonNativeVisibleMenu
        }

        toggleFullscreen(mode: mode)
    }

    @objc func takoConfigDidChange(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a
        // surface-specific one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.TakoConfigChangeKey
        ] as? Tako.Config else { return }

        // Update our derived config
        self.derivedConfig = DerivedConfig(config)

        syncAppearance()

        terminalViewContainer?.takoConfigDidChange(config, preferredBackgroundColor: nil)
    }

    @objc func onNewTab(notification: SwiftUI.Notification) {
        guard let surfaceView = notification.object as? Tako.SurfaceView else { return }
        guard let window = surfaceView.window else { return }
        guard window.windowController is QuickTerminalController else { return }
        // Tabs aren't supported with Quick Terminals or derivatives
        showNoNewTabAlert()
    }
}
