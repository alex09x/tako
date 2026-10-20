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
import Testing
@testable import Tako

/// `takoctl tab-new --no-select`: the new tab joins its window's group hidden.
/// It used to be shown like any new tab and the key window handed back after:
/// the tab stayed on screen under the chosen one, and with Tako in the
/// background -- no key window to hand back -- it stayed chosen, Tako brought
/// forward over the user's app.
@Suite(.serialized) @MainActor
struct BackgroundTabTests {
    @Test func anUnselectedTabJoinsHiddenAndTheChosenTabStays() throws {
        let (parent, window) = TerminalTestSupport.loaded()
        let group = Tako.CustomTabGroup.group(for: window)
        let created = try #require(withInjectedWindowSystem { TerminalController.newTab(parent.tako, from: window, select: false) })
        let tab = try #require(created.window)
        defer {
            Tako.CustomTabGroup.leave(tab)
            Tako.CustomTabGroup.leave(window)
            withExtendedLifetime([parent, created, window, tab] as [AnyObject]) {}
        }

        // Past the turn a new tab is presented on.
        TerminalTestSupport.waitUntil(timeout: 0.3) { false }
        #expect(group.windows.contains(tab))
        #expect(group.selectedWindow === window)
        #expect(!tab.isVisible)
        #expect(!tab.isKeyWindow)
    }
}
