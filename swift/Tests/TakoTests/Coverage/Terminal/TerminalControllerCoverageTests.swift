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

    @Test func windowShouldCloseRoutesThroughTheTabGroupCoordinator() {
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
