/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import AppKit
@testable import Tako

@MainActor
private func makeHiddenTitlebarWindow() -> HiddenTitlebarTerminalWindow {
    HiddenTitlebarTerminalWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
}

@MainActor
struct HiddenTitlebarTerminalWindowCoverageTests {
    @Test func awakeFromNibHidesTitlebarChrome() {
        withAppDelegate { _ in
            let window = makeHiddenTitlebarWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarAppearsTransparent)
            #expect(window.tabbingMode == .disallowed)
        }
    }

    @Test func settingTitleReappliesTheHiddenStyle() {
        withAppDelegate { _ in
            let window = makeHiddenTitlebarWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.title = "New Title"
            #expect(window.titleVisibility == .hidden)
        }
    }

    @Test func contentLayoutRectFillsTheFullFrame() {
        let window = makeHiddenTitlebarWindow()
        defer { window.orderOut(nil) }
        let rect = window.contentLayoutRect
        #expect(rect.origin.y == 0)
        #expect(rect.size.height == window.frame.height)
    }

    @Test func fullscreenDidExitIgnoresUnrelatedNotifications() {
        withAppDelegate { _ in
            let window = makeHiddenTitlebarWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            NotificationCenter.default.post(name: .fullscreenDidExit, object: NSObject())
            #expect(true)
        }
    }

    @Test func fullscreenDidExitIgnoresNotificationsWithoutAFullscreenObject() {
        withAppDelegate { _ in
            let window = makeHiddenTitlebarWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            NotificationCenter.default.post(name: .fullscreenDidExit, object: nil)
            #expect(true)
        }
    }
}
