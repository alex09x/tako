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
        defer { window.close() }
        Tako.TabBarController.install(in: window)

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
    }

    /// Restored in the background, a window is never key; a question
    /// answered in it ("Install the takoctl command?") left the strip hidden
    /// under the titlebar's background until the window was clicked.
    @Test func aDialogClosingInAWindowThatIsNotKeyBringsTheStripBack() async throws {
        let window = makeWindow(title: "dialog-closed")
        defer { window.close() }
        Tako.TabBarController.install(in: window)
        let themeFrame = try #require(window.contentView?.superview)
        let titlebarContainer = try #require(themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView"))
        let asked = Task {
            await TerminalDialogView.choose(in: window, title: "Install?", lines: [],
                                            choices: [.init(title: "Not Now", kind: .primary)], cancelIndex: 0, theme: nil)
        }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        // What AppKit does meanwhile: paints the titlebar's background again.
        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = NSColor.red.cgColor
        TerminalDialogView.pending(in: window)?.removeFromSuperview()
        _ = await asked.value

        #expect(!window.isKeyWindow)
        #expect(titlebarContainer.layer?.backgroundColor == NSColor.clear.cgColor)
    }

    @Test func becomeMainNotificationClearsBackgroundAndResetsOpaque() throws {
        let window = makeWindow(title: "main-notified")
        defer { window.close() }
        Tako.TabBarController.install(in: window)

        let themeFrame = try #require(window.contentView?.superview)
        let titlebarContainer = try #require(themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView"))

        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = NSColor.red.cgColor
        titlebarContainer.layer?.isOpaque = true

        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(titlebarContainer.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(titlebarContainer.layer?.isOpaque == false)
    }

    @Test func closingSecondTabKeepsSurvivingTabIndicatorActiveAndClearsBadges() throws {
        let first = makeWindow(title: "first")
        let second = makeWindow(title: "second")
        defer {
            Tako.CustomTabGroup.leave(first)
            Tako.CustomTabGroup.leave(second)
        }

        Tako.TabBarController.install(in: first)
        Tako.TabBarController.install(in: second)
        Tako.CustomTabGroup.join(second, to: first, select: true)

        let bar = try #require(first.contentView?.subviews.compactMap { $0 as? Tako.TabBarView }.first)

        // Simulate Command held (e.g. Cmd+W pressed)
        bar.commandKeyChanged(held: true)

        // Close the second window
        Tako.CustomTabGroup.leave(second)
        second.close()

        // Group now has only `first` window
        let group = Tako.CustomTabGroup.group(for: first)
        #expect(group.windows == [first])
        #expect(group.selectedWindow === first)

        bar.layoutTabs()
        #expect(bar.windows.count == 1)
        #expect(bar.showingBadges == false)
        if bar.effectiveTabStyle == .pill {
            #expect(bar.tabs.count == 1)
            #expect(bar.tabs[0].isActive == true)
            // The indicator follows the tab's state, not its selection, as
            // its painted ring does: an idle tab is idle chosen or not. (The
            // "active means green" rule left the code in e749c17e, which
            // wrote this test against it.)
            #expect(bar.pillIndicatorColor(for: bar.tabs[0]) == Tako.tabStatusColor(for: "dim"))
        }
    }
}

