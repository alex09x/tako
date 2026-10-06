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
import Foundation
import Testing
@testable import Tako

// MARK: - TabBarController

@Suite
@MainActor
struct TabBarControllerCoverageTests {
    @Test func contentTopInsetIsZeroBeforeInstall() {
        let window = makeWindow(title: "uninstalled")
        #expect(Tako.TabBarController.contentTopInset(for: window) == 0)
    }

    @Test func installAddsTheBarAndInsetsContent() {
        let window = makeWindow(title: "installed")
        Tako.TabBarController.install(in: window)
        #expect(Tako.TabBarController.contentTopInset(for: window) == Tako.TabBarController.barHeight)
        #expect(window.contentView?.subviews.contains { $0 is Tako.TabBarView } == true)

        // Installing twice on the same window is a no-op past the first call.
        Tako.TabBarController.install(in: window)
        #expect(window.contentView?.subviews.filter { $0 is Tako.TabBarView }.count == 1)

        window.close()
        #expect(Tako.TabBarController.contentTopInset(for: window) == 0)
    }

    @Test func refreshAllIsSafeWithAndWithoutInstalledBars() {
        Tako.TabBarController.refreshAll() // No bars installed yet anywhere: must not crash.

        let window = makeWindow(title: "refresh")
        Tako.TabBarController.install(in: window)
        Tako.TabBarController.refreshAll()

        // The bar survives refreshAll intact -- installed exactly once, not
        // duplicated or torn down.
        #expect(Tako.TabBarController.contentTopInset(for: window) == Tako.TabBarController.barHeight)
        #expect(window.contentView?.subviews.filter { $0 is Tako.TabBarView }.count == 1)
        window.close()
    }

    @Test func clearTitlebarBackgroundOnAWindowWithoutATitlebarContainerIsANoOp() {
        let window = makeWindow(title: "no-container")
        // Before the window's view hierarchy is realized there may be no
        // NSTitlebarContainerView to find; either way nothing in the view
        // hierarchy is added or removed by the call.
        let before = window.contentView?.superview?.subviews.count
        Tako.TabBarController.clearTitlebarBackground(in: window)
        let after = window.contentView?.superview?.subviews.count
        #expect(before == after)
    }

    @Test func resizeAndKeyNotificationsReapplyTitlebarBackgroundWithoutCrashing() throws {
        let window = makeWindow(title: "notified")
        Tako.TabBarController.install(in: window)
        window.makeKeyAndOrderFront(nil)

        let themeFrame = try #require(window.contentView?.superview)
        let titlebarContainer = try #require(themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView"))

        func dirty() {
            titlebarContainer.wantsLayer = true
            titlebarContainer.layer?.backgroundColor = NSColor.red.cgColor
        }

        for name: NSNotification.Name in [
            NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWindow.didEndLiveResizeNotification,
        ] {
            dirty()
            NotificationCenter.default.post(name: name, object: window)
            #expect(titlebarContainer.layer?.backgroundColor == NSColor.clear.cgColor)
        }
        window.close()
    }
}

