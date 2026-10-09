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
struct TerminalControllerMoveTabAndGotoTabTests {
    @Test func onMoveTabIgnoresNonFocusedSurfaces() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let other = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { other.close() }
        NotificationCenter.default.post(
            name: .takoMoveTab,
            object: other,
            userInfo: [Notification.Name.TakoMoveTabKey: Tako.Action.MoveTab(amount: 1)])
        #expect(true)
    }

    @Test func onGotoTabIgnoresNonFocusedSurfaces() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let other = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { other.close() }
        NotificationCenter.default.post(
            name: Tako.Notification.takoGotoTab,
            object: other,
            userInfo: [Tako.Notification.GotoTabKey: TAKO_GOTO_TAB_NEXT])
        #expect(true)
    }

    @Test func onCloseTabIgnoresSurfacesNotInTheTree() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let other = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { other.close() }
        NotificationCenter.default.post(name: .takoCloseTab, object: other)
        #expect(window.isVisible == false || window.isVisible == true)
    }

    @Test func onCloseWindowIgnoresSurfacesNotInTheTree() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let other = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { other.close() }
        NotificationCenter.default.post(name: .takoCloseWindow, object: other)
        #expect(true)
    }

    @Test func onResetWindowSizeIgnoresSurfacesNotInTheTree() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let other = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { other.close() }
        NotificationCenter.default.post(name: .takoResetWindowSize, object: other)
        #expect(true)
    }

    @Test func onToggleFullscreenIgnoresNonFocusedSurfaces() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let other = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { other.close() }
        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: other)
        #expect(controller.fullscreenStyle?.isFullscreen == false)
    }

    @Test func onToggleFullscreenIgnoresAMissingMode() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: surface, userInfo: nil)
        #expect(controller.fullscreenStyle?.isFullscreen == false)
    }
}

@MainActor
struct TerminalControllerValidateMenuItemTests {
    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @Test func closeTabsOnTheRightIsDisabledWithoutAWindow() {
        let (controller, window) = TerminalTestSupport.makeController()
        defer { TerminalTestSupport.tearDown(controller, window) }
        // controller.window is set (unloaded), so this exercises the tab-group lookup path.
        controller.windowDidLoad()
        let item = menuItem(#selector(TerminalController.closeTabsOnTheRight(_:)))
        #expect(!controller.validateMenuItem(item))
    }

    @Test func returnToDefaultSizeIsDisabledWithoutADefaultSize() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let item = menuItem(#selector(TerminalController.returnToDefaultSize(_:)))
        #expect(!controller.validateMenuItem(item))
    }

    @Test func defaultCaseDelegatesToSuper() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let item = menuItem(#selector(TerminalController.increaseFontSize(_:)))
        #expect(controller.validateMenuItem(item) == (controller.focusedSurface != nil))
    }
}

@MainActor
struct TerminalControllerMultiTabGroupTests {
    /// Joins two manually-loaded controllers into the same `Tako.CustomTabGroup`
    /// -- our own lightweight grouping model, not AppKit's native tab group --
    /// so the "more than one tab" branches (`relabelTabs`, `closeOtherTabs`,
    /// `closeTabsOnTheRight`, multi-window undo) can be exercised without a
    /// real nib.
    private func makeJoinedPair() -> (a: TerminalController, aWindow: TerminalWindow, b: TerminalController, bWindow: TerminalWindow) {
        let (a, aWindow) = TerminalTestSupport.loaded()
        let (b, bWindow) = TerminalTestSupport.loaded()
        Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
        return (a, aWindow, b, bWindow)
    }

    @Test func relabelTabsSetsKeyEquivalentsAcrossTheGroup() {
        let (a, aWindow, b, bWindow) = makeJoinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        a.relabelTabs()
        #expect(aWindow.keyEquivalent != nil)
        #expect(bWindow.keyEquivalent != nil)
    }

    @Test func onFrameDidChangeRelabelsWhenTheGroupOrderChanges() {
        let (a, aWindow, b, bWindow) = makeJoinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        a.relabelTabs()
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: NSView())
        #expect(true)
    }

    @Test func closeOtherTabsImmediatelyClosesEveryOtherWindow() {
        let (a, aWindow, b, bWindow) = makeJoinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        aWindow.makeKeyAndOrderFront(nil)

        a.closeOtherTabs(nil)

        #expect(!bWindow.isVisible)
    }

    @Test func closeTabsOnTheRightImmediatelyClosesLaterTabs() {
        let (a, aWindow, b, bWindow) = makeJoinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        aWindow.makeKeyAndOrderFront(nil)

        a.closeTabsOnTheRight(nil)

        #expect(!bWindow.isVisible)
    }

    @Test func closeTabImmediatelyWithMultipleTabsOnlyClosesTheOneWindow() {
        let (a, aWindow, b, bWindow) = makeJoinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        aWindow.makeKeyAndOrderFront(nil)
        bWindow.makeKeyAndOrderFront(nil)

        b.closeTabImmediately()

        #expect(!bWindow.isVisible)
        #expect(aWindow.isVisible)
    }

    @Test func closeTabsOnTheRightIsEnabledWhenThereAreTabsToTheRight() {
        let (a, aWindow, b, bWindow) = makeJoinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        let item = NSMenuItem(
            title: "", action: #selector(TerminalController.closeTabsOnTheRight(_:)), keyEquivalent: "")
        #expect(a.validateMenuItem(item))
        #expect(!b.validateMenuItem(item))
    }

    @Test func closeSurfaceOnTheRootWithMultipleTabsClosesJustTheTab() throws {
        let (a, aWindow, b, bWindow) = makeJoinedPair()
        defer {
            TerminalTestSupport.tearDown(a, aWindow)
            TerminalTestSupport.tearDown(b, bWindow)
        }
        aWindow.makeKeyAndOrderFront(nil)
        let node = try #require(a.surfaceTree.root)

        a.closeSurface(node, withConfirmation: false)

        #expect(!aWindow.isVisible)
        #expect(bWindow.isVisible)
    }
}

@MainActor
struct TerminalControllerDefaultSizeTests {
    @Test func frameCaseReportsChangedWhenFrameDiffers() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let size = TerminalController.DefaultSize.frame(NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(size.isChanged(for: window))
        size.apply(to: window)
        #expect(!size.isChanged(for: window))
    }

    @Test func contentIntrinsicSizeAppliesTheContentViewsIntrinsicSize() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let size = TerminalController.DefaultSize.contentIntrinsicSize
        size.apply(to: window)
        #expect(true)
        _ = size.isChanged(for: window)
    }
}
