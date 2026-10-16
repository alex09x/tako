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

/// After a normal quit AppKit restores each tab as a window of its own,
/// where it last stood; the layout journal puts them back into one group.
@Suite(.serialized)
@MainActor
struct LayoutRegroupTests {
    private func restoredWindow(_ app: Tako.App, at origin: CGPoint) -> TerminalController {
        let controller = TerminalController(app)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: CGSize(width: 500, height: 300)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.orderFrontRegardless()
        return controller
    }

    @Test func tabsAppKitBroughtBackAsSeparateWindowsAreOneGroupAgain() throws {
        let app = Tako.App()
        let controllers = [CGPoint(x: 100, y: 100), CGPoint(x: 290, y: 180), CGPoint(x: 400, y: 60)]
            .map { restoredWindow(app, at: $0) }
        defer {
            for c in controllers {
                if let w = c.window { Tako.CustomTabGroup.leave(w) }
                c.surfaceTree.forEach { $0.pty?.terminate() }
                c.window?.close()
            }
        }
        let windows = controllers.compactMap(\.window)
        #expect(windows.allSatisfy { $0.isVisible })

        // The journal the last run wrote: one window, these three tabs, the
        // second selected.
        let encoder = JSONEncoder()
        let tabs: [Any] = try controllers.map {
            try JSONSerialization.jsonObject(with: encoder.encode(TerminalRestorableState(from: $0)))
        }
        let journal = LayoutJournal.Journal(generation: 1, windows: [
            LayoutJournal.Window(frame: windows[1].frame, isKey: true, selectedTab: 1, tabs: tabs),
        ])

        LayoutRecorder.regroup(journal)

        let group = Tako.CustomTabGroup.group(for: windows[0])
        let grouped = group.windows.map { ObjectIdentifier($0) }
        let expected = windows.map { ObjectIdentifier($0) }
        #expect(grouped == expected)
        #expect(group.selectedWindow === windows[1])
        // Only the selected tab is on screen; the others stand where it does.
        #expect(windows[1].isVisible)
        #expect(!windows[0].isVisible && !windows[2].isVisible)
        #expect(windows[0].frame == windows[1].frame && windows[2].frame == windows[1].frame)
    }
}
