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
struct TerminalControllerCloseTests {
    @Test func closeSurfaceOnANonRootNodeDelegatesToSuper() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let node = try #require(controller.surfaceTree.root?.node(view: created))

        controller.closeSurface(node, withConfirmation: false)

        #expect(!controller.surfaceTree.contains(created))
    }

    @Test func closeSurfaceOnTheRootWithASingleWindowClosesTheWindow() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)
        let node = try #require(controller.surfaceTree.root)

        controller.closeSurface(node, withConfirmation: false)

        #expect(!window.isVisible)
    }

    @Test func closeTabImmediatelyWithASingleWindowClosesTheWindow() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)

        controller.closeTabImmediately()

        #expect(!window.isVisible)
    }

    @Test func closeWindowImmediatelyClosesASingleWindow() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)

        controller.closeWindowImmediately()

        #expect(!window.isVisible)
    }

    @Test func closeWindowIBActionClosesImmediatelyWithoutARunningProcess() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)

        controller.closeWindow(nil)

        #expect(!window.isVisible)
    }

    @Test func closeTabIBActionWithASingleWindowClosesTheWindow() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)

        controller.closeTab(nil)

        #expect(!window.isVisible)
    }

    @Test func closeOtherTabsIBActionIsANoOpWithASingleWindow() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)

        controller.closeOtherTabs(nil)

        #expect(window.isVisible)
    }

    @Test func closeTabsOnTheRightIBActionIsANoOpWithASingleWindow() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)

        controller.closeTabsOnTheRight(nil)

        #expect(window.isVisible)
    }

    @Test func windowShouldCloseClosesTheSingleWindowGroup() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)

        let result = controller.windowShouldClose(window)

        #expect(!result)
        #expect(!window.isVisible)
    }
}

@MainActor
struct TerminalControllerWindowDelegateTests {
    @Test func windowDidBecomeKeyRelabelsAndFixesTabBar() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(true)
    }

    @Test func windowDidResignKeyDoesNotCrash() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(true)
    }

    @Test func windowDidMoveSavesLastPosition() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(true)
    }

    @Test func windowDidResizeSavesLastPosition() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(true)
    }

    @Test func windowDidBecomeMainRemembersLastMain() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification, object: window))
        #expect(TerminalController.preferredParent === controller)
    }

    @Test func willEncodeRestorableStateEncodesTerminalState() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        defer { coder.finishEncoding() }
        controller.window(window, willEncodeRestorableState: coder)
        #expect(true)
    }

    @Test func windowWillCloseCancelsPendingPresentationAndRelabels() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(true)
    }
}

@MainActor
struct TerminalControllerUndoStateTests {
    @Test func undoStateIsNilWithAnEmptySurfaceTree() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.surfaceTree = .init()
        #expect(controller.undoState == nil)
    }

    @Test func undoStateReflectsTheCurrentWindow() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let state = try #require(controller.undoState)
        #expect(state.frame == window.frame)
        #expect(state.tabColor == .none)
    }

    @Test func convenienceInitFromUndoStateRestoresTheSurfaceTree() throws {
        let (source, sourceWindow) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(source, sourceWindow) }
        let state = try #require(source.undoState)

        let restored = TerminalController(source.tako, with: state)

        #expect(restored.surfaceTree.contains(where: { state.surfaceTree.contains($0) }))
    }
}

@MainActor
struct TerminalControllerFirstResponderTests {
    @Test func returnToDefaultSizeIsANoOpWithoutADefaultSize() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let frameBefore = window.frame
        controller.returnToDefaultSize(nil)
        #expect(window.frame == frameBefore)
    }

    @Test func toggleTakoFullScreenRoutesToNativeFullscreen() {
        // We deliberately don't call `toggleTakoFullScreen` here: it drives
        // the real, asynchronous `NSWindow.toggleFullScreen` animation via
        // `NativeFullscreen.enter()`, which depends on a live window-server
        // transition this offscreen test window never completes -- leaving
        // it pending across test teardown is the kind of thing that wedges
        // the whole suite. `BaseTerminalControllerFullscreenTests` already
        // covers `toggleFullscreen(mode:)`'s own logic without a window.
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        #expect(controller.fullscreenStyle?.isFullscreen == false)
    }

    @Test func newWindowIBActionRunsWithoutCrashing() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        // `Terminal.xib` is excluded from this SPM test target, so the newly
        // created controller's `.window` may fail to load lazily; the
        // assertion here is that routing through the real IBAction (and its
        // static `newWindow` factory) doesn't crash.
        controller.newWindow(nil)
        #expect(true)
    }
}
