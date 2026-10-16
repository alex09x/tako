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

/// Only the chosen tab of a group is on screen, however it was chosen.
@Suite(.serialized)
@MainActor
struct TabGroupSelectTests {
    private func window(_ title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 300),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = title
        return w
    }

    @Test func choosingATabTwiceInARowStillHidesTheOneBefore() async throws {
        let a = window("a"), b = window("b")
        defer {
            for w in [a, b] { Tako.CustomTabGroup.leave(w); w.close() }
        }
        a.orderFrontRegardless()
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)
        group.select(a)
        try await Task.sleep(for: .milliseconds(50))
        #expect(a.isVisible && !b.isVisible)

        // A sidebar click: the sidebar selects, then presenting the pane
        // selects the same tab again.
        group.select(b)
        group.select(b)
        try await Task.sleep(for: .milliseconds(100))

        #expect(group.selectedWindow === b)
        #expect(b.isVisible)
        #expect(!a.isVisible)
    }
}
