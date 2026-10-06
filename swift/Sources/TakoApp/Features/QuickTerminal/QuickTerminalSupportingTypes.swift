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

extension QuickTerminalController {
    struct DerivedConfig {
        let quickTerminalScreen: QuickTerminalScreen
        let quickTerminalAnimationDuration: Double
        let quickTerminalAutoHide: Bool
        let quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior
        let quickTerminalSize: QuickTerminalSize
        let backgroundOpacity: Double
        let backgroundBlur: Tako.Config.BackgroundBlur

        init() {
            self.quickTerminalScreen = .main
            self.quickTerminalAnimationDuration = 0.2
            self.quickTerminalAutoHide = true
            self.quickTerminalSpaceBehavior = .move
            self.quickTerminalSize = QuickTerminalSize()
            self.backgroundOpacity = 1.0
            self.backgroundBlur = .disabled
        }

        init(_ config: Tako.Config) {
            self.quickTerminalScreen = config.quickTerminalScreen
            self.quickTerminalAnimationDuration = config.quickTerminalAnimationDuration
            self.quickTerminalAutoHide = config.quickTerminalAutoHide
            self.quickTerminalSpaceBehavior = config.quickTerminalSpaceBehavior
            self.quickTerminalSize = config.quickTerminalSize
            self.backgroundOpacity = config.backgroundOpacity
            self.backgroundBlur = config.backgroundBlur
        }
    }
}

/// Hides the dock globally (not just NSApp). This is only used if the quick terminal is
/// in a conflicting position with the dock.
class HiddenDock {
    let previousAutoHide: Bool
    private var hidden: Bool = false

    init() {
        previousAutoHide = Dock.autoHideEnabled
    }

    deinit {
        restore()
    }

    func hide() {
        guard !hidden else { return }
        NSApp.acquirePresentationOption(.autoHideDock)
        Dock.autoHideEnabled = true
        hidden = true
    }

    func restore() {
        guard hidden else { return }
        NSApp.releasePresentationOption(.autoHideDock)
        Dock.autoHideEnabled = previousAutoHide
        hidden = false
    }
}

extension Notification.Name {
    /// The quick terminal did become hidden or visible.
    static let quickTerminalDidChangeVisibility = Notification.Name("QuickTerminalDidChangeVisibility")
}
