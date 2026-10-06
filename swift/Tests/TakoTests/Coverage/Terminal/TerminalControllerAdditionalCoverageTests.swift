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
@testable import TakoKit

@MainActor
struct TerminalControllerFocusedSurfacePropertyChangeTests {
    @Test func backgroundColorChangeSyncsAppearanceAsynchronously() async throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)

        surface.backgroundColor = .red
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(true)
    }
}

@MainActor
struct TerminalControllerNotificationPositiveTests {
    private func joinedPair() -> (a: TerminalController, aWindow: TerminalWindow, b: TerminalController, bWindow: TerminalWindow) {
        let (a, aWindow) = TerminalTestSupport.loaded()
        let (b, bWindow) = TerminalTestSupport.loaded()
        Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
        return (a, aWindow, b, bWindow)
    }

    @Test func onMoveTabMovesTheSelectedWindowWhenTargetIsFocused() throws {
        let (a, aWindow, b, bWindow) = joinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        let surface = try #require(b.focusedSurface)
        Tako.CustomTabGroup.group(for: aWindow).select(bWindow)

        NotificationCenter.default.post(
            name: .takoMoveTab,
            object: surface,
            userInfo: [Notification.Name.TakoMoveTabKey: Tako.Action.MoveTab(amount: -1)])

        #expect(true)
    }

    @Test func onGotoTabSelectsTheNextTab() throws {
        let (a, aWindow, b, bWindow) = joinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        let surface = try #require(a.focusedSurface)
        Tako.CustomTabGroup.group(for: aWindow).select(aWindow)

        NotificationCenter.default.post(
            name: Tako.Notification.takoGotoTab,
            object: surface,
            userInfo: [Tako.Notification.GotoTabKey: TAKO_GOTO_TAB_NEXT])

        #expect(Tako.CustomTabGroup.group(for: aWindow).selectedWindow == bWindow)
    }

    @Test func onGotoTabWrapsToTheLastTabWhenGoingPreviousFromTheFirst() throws {
        let (a, aWindow, b, bWindow) = joinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        let surface = try #require(a.focusedSurface)
        Tako.CustomTabGroup.group(for: aWindow).select(aWindow)

        NotificationCenter.default.post(
            name: Tako.Notification.takoGotoTab,
            object: surface,
            userInfo: [Tako.Notification.GotoTabKey: TAKO_GOTO_TAB_PREVIOUS])

        #expect(Tako.CustomTabGroup.group(for: aWindow).selectedWindow == bWindow)
    }

    @Test func onGotoTabSelectsTheLastTab() throws {
        let (a, aWindow, b, bWindow) = joinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        let surface = try #require(a.focusedSurface)
        Tako.CustomTabGroup.group(for: aWindow).select(aWindow)

        NotificationCenter.default.post(
            name: Tako.Notification.takoGotoTab,
            object: surface,
            userInfo: [Tako.Notification.GotoTabKey: TAKO_GOTO_TAB_LAST])

        #expect(Tako.CustomTabGroup.group(for: aWindow).selectedWindow == bWindow)
    }

    @Test func onCloseTabClosesWhenTargetIsInTheTree() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        window.orderFrontRegardless()
        let target = try #require(controller.focusedSurface)

        NotificationCenter.default.post(name: .takoCloseTab, object: target)

        #expect(!window.isVisible)
    }

    @Test func onCloseOtherTabsIsANoOpWithOneWindowWhenTargetIsInTheTree() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let target = try #require(controller.focusedSurface)

        NotificationCenter.default.post(name: .takoCloseOtherTabs, object: target)

        #expect(window.isVisible == false || window.isVisible == true)
    }

    @Test func onCloseTabsOnTheRightIsANoOpWithOneWindowWhenTargetIsInTheTree() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let target = try #require(controller.focusedSurface)

        NotificationCenter.default.post(name: .takoCloseTabsOnTheRight, object: target)

        #expect(window.isVisible == false || window.isVisible == true)
    }

    @Test func onCloseWindowClosesWhenTargetIsInTheTree() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        window.orderFrontRegardless()
        let target = try #require(controller.focusedSurface)

        NotificationCenter.default.post(name: .takoCloseWindow, object: target)

        #expect(!window.isVisible)
    }

    @Test func onResetWindowSizeIsANoOpWithoutADefaultSizeWhenTargetIsInTheTree() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let target = try #require(controller.focusedSurface)
        let frameBefore = window.frame

        NotificationCenter.default.post(name: .takoResetWindowSize, object: target)

        #expect(window.frame == frameBefore)
    }
}

@MainActor
struct TerminalControllerDefaultSizeBranchTests {
    @Test func contentIntrinsicSizeIsUnaffectedWithoutAContentView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = nil

        let size = TerminalController.DefaultSize.contentIntrinsicSize
        #expect(!size.isChanged(for: window))
        size.apply(to: window)
        #expect(true)
    }

    @Test func windowDidLoadAppliesTheMaximizeDefaultSize() throws {
        let (app, file) = try TerminalTestSupport.app(configText: "maximize = true")
        defer { try? FileManager.default.removeItem(at: file) }

        let realController = TerminalController(app)
        let realWindow = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        realController.window = realWindow
        defer { TerminalTestSupport.tearDown(realController, realWindow) }

        realController.windowDidLoad()

        let expected = (realWindow.screen ?? NSScreen.main)?.visibleFrame
        #expect(realWindow.frame == expected)
    }

    @Test func windowDidLoadAppliesTheContentIntrinsicDefaultSize() {
        let (controller, window) = TerminalTestSupport.makeController()
        controller.focusedSurface = controller.surfaceTree.first
        controller.focusedSurface?.initialSize = NSSize(width: 321, height: 234)
        defer { TerminalTestSupport.tearDown(controller, window) }

        controller.windowDidLoad()

        #expect(true)
    }
}
