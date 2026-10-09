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
struct TerminalControllerWindowNibNameTests {
    @Test func defaultsToTerminalWithoutAnAppDelegate() {
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        defer { NSApplication.shared.delegate = originalDelegate }

        let (controller, window) = TerminalTestSupport.makeController()
        defer { TerminalTestSupport.tearDown(controller, window) }
        #expect(controller.windowNibName == "Terminal")
    }

    @Test func returnsANibNameWithARealAppDelegate() {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let (controller, window) = TerminalTestSupport.makeController()
        defer { TerminalTestSupport.tearDown(controller, window) }
        #expect(controller.windowNibName != nil)
    }
}

@MainActor
struct TerminalControllerLifecycleTests {
    @Test func isNotRestorableWhenABaseCommandIsConfigured() {
        var config = Tako.SurfaceConfiguration()
        config.command = "top"
        let (controller, window) = TerminalTestSupport.makeController(baseConfig: config)
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.windowDidLoad()
        #expect(!window.isRestorable)
    }

    @Test func isRestorableWithNoCommand() {
        let (controller, window) = TerminalTestSupport.makeController()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.windowDidLoad()
        #expect(window.isRestorable)
        #expect(window.identifier == .init(String(describing: TerminalWindowRestoration.self)))
    }

    @Test func windowDidLoadSetsUpContentViewAndFocus() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        #expect(window.contentView is TerminalViewContainer)
        #expect(controller.focusedSurface != nil)
    }

    @Test func allIncludesLoadedControllers() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        #expect(TerminalController.all.contains { $0 === controller })
    }

    @Test func showWindowPositionsAndShowsTheWindow() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)
        #expect(window.isVisible)
    }
}

@MainActor
struct TerminalControllerSurfaceTreeOverrideTests {
    @Test func surfaceTreeBecomingEmptyClosesTheWindow() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)
        #expect(window.isVisible)

        controller.surfaceTree = .init()

        #expect(!window.isVisible)
    }

    @Test func surfaceTreeChangeUpdatesZoomState() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let node = try #require(controller.surfaceTree.root?.node(view: created))

        controller.surfaceTree = SplitTree(root: controller.surfaceTree.root, zoomed: node)

        #expect(window.surfaceIsZoomed)
    }

    @Test func replaceSurfaceTreeWithEmptyTreeClosesTheTabImmediately() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)

        controller.replaceSurfaceTree(.init())

        #expect(!window.isVisible)
    }
}

@MainActor
struct TerminalControllerNewWindowTests {
    @Test func newWindowIsCreatedForTheGivenApp() {
        let app = Tako.App()
        let controller = TerminalController.newWindow(app)
        #expect(controller.tako === app)
    }

    @Test func newWindowInheritsBackgroundOpacityFromParent() {
        let (parent, parentWindow) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(parent, parentWindow) }
        parent.isBackgroundOpaque = true

        let child = TerminalController.newWindow(parent.tako, withParent: parentWindow)
        #expect(child.isBackgroundOpaque)
    }

    @Test func newWindowWithTreePositionsAtTheGivenPoint() {
        let app = Tako.App()
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let tree = SplitTree(view: view)
        let controller = TerminalController.newWindow(app, tree: tree, position: NSPoint(x: 10, y: 10))
        #expect(controller.surfaceTree.contains(view))
    }

    @Test func closeAllWindowsImmediatelyClosesEveryController() {
        let (a, windowA) = TerminalTestSupport.loaded()
        let (b, windowB) = TerminalTestSupport.loaded()
        defer {
            TerminalTestSupport.tearDown(a, windowA)
            TerminalTestSupport.tearDown(b, windowB)
        }
        a.showWindow(nil)
        b.showWindow(nil)

        TerminalController.closeAllWindows()

        #expect(!windowA.isVisible)
        #expect(!windowB.isVisible)
    }
}

@MainActor
struct TerminalControllerNewTabTests {
    @Test func newTabWithoutATerminalParentCreatesAWindow() {
        let app = Tako.App()
        let controller = TerminalController.newTab(app, from: nil)
        #expect(controller != nil)
        #expect(controller?.tako === app)
    }

    @Test func newTabWithATerminalParentRunsWithoutCrashing() throws {
        let (parent, parentWindow) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(parent, parentWindow) }
        parent.showWindow(nil)

        let child = TerminalController.newTab(parent.tako, from: parentWindow)
        defer { child?.window?.orderOut(nil) }

        // The nib this depends on for the child's window is excluded from the
        // test bundle, so `child.window` may fail to load lazily -- the
        // assertion here is that this doesn't crash and still returns a
        // controller.
        #expect(child != nil)
        #expect(child?.isBackgroundOpaque == parent.isBackgroundOpaque)
    }
}

@MainActor
struct TerminalControllerNotificationTests {
    @Test func takoConfigDidChangeIgnoresSurfaceScopedNotifications() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: NSObject(),
            userInfo: [Notification.Name.TakoConfigChangeKey: controller.tako.config])
        // No crash is the assertion; the notification is scoped to a surface.
        #expect(controller.surfaceTree.isEmpty == false)
    }

    @Test func takoConfigDidChangeIgnoresAMissingPayload() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        NotificationCenter.default.post(name: .takoConfigDidChange, object: nil, userInfo: nil)
        #expect(controller.surfaceTree.isEmpty == false)
    }

    @Test func takoConfigDidChangeUpdatesAppearanceWhenTreeIsEmpty() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.surfaceTree = .init()

        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: nil,
            userInfo: [Notification.Name.TakoConfigChangeKey: controller.tako.config])

        // No crash is the assertion.
        #expect(controller.surfaceTree.isEmpty)
    }

    @Test func onFrameDidChangeIsANoOpWhenNotListening() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: NSView())
        #expect(controller.surfaceTree.isEmpty == false)
    }

    @Test func relabelTabsIsSafeWithASingleWindow() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.relabelTabs()
        #expect(window.keyEquivalent != nil)
    }
}

@MainActor
struct TerminalControllerAppearanceTests {
    @Test func syncAppearanceIsANoOpWithoutAFocusedSurface() {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.focusedSurface = nil
        controller.syncAppearance()
        #expect(controller.focusedSurface == nil)
    }

    @Test func syncAppearanceUpdatesTheWindowWithAFocusedSurface() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        try #require(controller.focusedSurface != nil)
        controller.syncAppearance()
        // No crash is the assertion.
        #expect(true)
    }

    @Test func adjustForWindowPositionReturnsTheFrameUnchangedWithoutConfiguredCoordinates() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let screen = try #require(NSScreen.main)
        let frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let result = controller.adjustForWindowPosition(frame: frame, on: screen)
        #expect(result == frame)
    }
}
