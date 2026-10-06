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
    struct DerivedConfig {
        let initialWindow: Bool
        let shouldQuitAfterLastWindowClosed: Bool
        let quickTerminalPosition: QuickTerminalPosition

        init() {
            self.initialWindow = true
            self.shouldQuitAfterLastWindowClosed = false
            self.quickTerminalPosition = .top
        }

        init(_ config: Tako.Config) {
            self.initialWindow = config.initialWindow
            self.shouldQuitAfterLastWindowClosed = config.shouldQuitAfterLastWindowClosed
            self.quickTerminalPosition = config.quickTerminalPosition
        }
    }
}

struct ToggleVisibilityState {
    let hiddenWindows: [Weak<NSWindow>]
    let keyWindow: Weak<NSWindow>?

    init() {
        // We need to know the key window so that we can bring focus back to the
        // right window if it was hidden.
        self.keyWindow = if let keyWindow = NSApp.keyWindow {
            .init(keyWindow)
        } else {
            nil
        }

        // We need to keep track of the windows that were visible because we only
        // want to bring back these windows if we remove the toggle.
        //
        // We also ignore fullscreen windows because they don't hide anyways.
        var visibleWindows = [Weak<NSWindow>]()
        NSApp.windows.filter {
            $0.isVisible &&
            !$0.styleMask.contains(.fullScreen)
        }.forEach { window in
            // We only keep track of selectedWindow if it's in a tabGroup,
            // so we can keep its selection state when restoring
            let windowToHide = window.tabGroup?.selectedWindow ?? window
            if !visibleWindows.contains(where: { $0.value === windowToHide }) {
                visibleWindows.append(Weak(windowToHide))
            }
        }
        self.hiddenWindows = visibleWindows
    }

    func restore() {
        hiddenWindows.forEach { $0.value?.orderFrontRegardless() }
        keyWindow?.value?.makeKey()
    }
}

enum QuickTerminalState {
    /// Controller has not been initialized and has no pending restoration state.
    case uninitialized
    /// Restoration state is pending; controller will use this when first accessed.
    case pendingRestore(QuickTerminalRestorableState)
    /// Controller has been initialized.
    case initialized(QuickTerminalController)
}
