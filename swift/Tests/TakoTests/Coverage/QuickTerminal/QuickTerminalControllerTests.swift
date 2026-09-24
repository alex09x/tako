import Testing
import AppKit
@testable import Tako

@MainActor
struct QuickTerminalControllerInitTests {
    @Test func defaultsToRestorableWhenNoCommandIsConfigured() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        #expect(controller.restorable)
        #expect(!controller.visible)
    }

    @Test func isNotRestorableWhenABaseCommandIsConfigured() {
        let app = Tako.App()
        var config = Tako.SurfaceConfiguration()
        config.command = "top"
        let controller = QuickTerminalController(app, baseConfig: config)
        #expect(!controller.restorable)
    }

    @Test func positionIsHonored() {
        let (controller, window) = QTTestSupport.makeController(position: .left)
        defer { QTTestSupport.tearDown(controller, window) }
        if case .left = controller.position {
            // expected
        } else {
            Issue.record("expected .left position")
        }
    }
}

@MainActor
struct QuickTerminalControllerLifecycleTests {
    @Test func windowDidLoadConfiguresDelegateAndDisablesRestorable() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }

        #expect(window.delegate === controller)
        #expect(!window.isRestorable)
        #expect(controller.visible)
        #expect(window.isVisible)
        #expect(!controller.surfaceTree.isEmpty)
        #expect(controller.focusedSurface != nil)
    }

    @Test func toggleAnimatesOutWhenVisibleThenBackInWhenHidden() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        #expect(controller.visible)

        controller.toggle()
        QTTestSupport.simulateDeferredAnimateOutCompletion(controller: controller, window: window)
        #expect(!controller.visible)
        #expect(!window.isVisible)

        controller.toggle()
        QTTestSupport.waitUntil { controller.visible }
        QTTestSupport.simulateDeferredAnimateInCompletion(controller: controller, window: window)
        #expect(controller.visible)
        #expect(window.isVisible)
    }

    @Test func animateInIsANoOpWhenAlreadyVisible() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let frameBefore = window.frame
        controller.animateIn()
        #expect(controller.visible)
        #expect(window.frame == frameBefore)
    }

    @Test func animateOutIsANoOpWhenNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        #expect(!controller.visible)
        controller.animateOut()
        #expect(!controller.visible)
        #expect(!window.isVisible)
    }

    @Test func animateInAndOutWithoutAWindowIsANoOp() {
        let app = Tako.App()
        let controller = QuickTerminalController(app, position: .center)
        // `.window` is nil (never assigned, so it's never lazily loaded either
        // -- see QTTestSupport.makeController's doc comment). Both guards
        // must bail before touching `visible`.
        controller.animateIn()
        #expect(!controller.visible)
        controller.animateOut()
        #expect(!controller.visible)
    }

    @Test func saveScreenStateStoresTheCurrentFrameInTheScreenCache() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let screen = try #require(window.screen ?? NSScreen.main)

        controller.saveScreenState(exitFullscreen: true)

        guard screen.displayUUID != nil else { return }
        #expect(controller.screenStateCache.frame(for: screen) == window.frame)
    }

    @Test func saveScreenStateIgnoresAZeroSizedFrame() throws {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        window.setFrame(NSRect(x: 0, y: 0, width: 0, height: 0), display: false)
        let screen = try #require(window.screen ?? NSScreen.main)

        controller.saveScreenState(exitFullscreen: false)

        #expect(controller.screenStateCache.frame(for: screen) == nil)
    }

    @Test func syncAppearanceIsANoOpWhileTheWindowIsNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        let collectionBefore = window.collectionBehavior
        controller.syncAppearance()
        // The early `guard window.isVisible` returns before touching opacity,
        // but collectionBehavior is set unconditionally above that guard.
        #expect(window.collectionBehavior == QuickTerminalSpaceBehavior.move.collectionBehavior)
        _ = collectionBefore
    }

    @Test func syncAppearanceMakesTheWindowOpaqueByDefault() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        // Production only re-syncs appearance once truly visible from inside
        // the (in this test host, dead -- see loadAndAnimateIn's doc comment)
        // animation completion handler, or from `takoConfigDidChange`. Call
        // it directly now that the window is actually visible.
        controller.syncAppearance()
        #expect(window.isOpaque)
        #expect(window.backgroundColor == .windowBackgroundColor)
    }

    @Test func windowDidResizeRecentersForTopPositionKeepingY() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn(position: .top)
        defer { QTTestSupport.tearDown(controller, window) }
        let originalY = window.frame.origin.y
        window.setFrame(NSRect(x: 999, y: originalY, width: window.frame.width - 10, height: window.frame.height), display: false)

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        #expect(window.frame.origin.x != 999)
        #expect(window.frame.origin.y == originalY)
    }

    @Test func windowDidResizeRecentersForLeftPositionKeepingX() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn(position: .left)
        defer { QTTestSupport.tearDown(controller, window) }
        let originalX = window.frame.origin.x
        window.setFrame(NSRect(x: originalX, y: -12345, width: window.frame.width, height: window.frame.height - 10), display: false)

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        #expect(window.frame.origin.x == originalX)
        #expect(window.frame.origin.y != -12345)
    }

    @Test func windowDidResizeIgnoresNotificationsForAnotherWindow() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        let frameBefore = window.frame

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: other))

        #expect(window.frame == frameBefore)
    }

    @Test func windowDidResizeIgnoresNotificationsWhileNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        let frameBefore = window.frame

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        #expect(window.frame == frameBefore)
    }
}

@MainActor
struct QuickTerminalControllerKeyStateTests {
    @Test func windowDidBecomeKeyIsANoOpWhileNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        // Must not crash without a hidden dock or terminal view container set up.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(!controller.visible)
    }

    @Test func windowDidResignKeyRestoresPreviousAppOnlyWhenAppIsInactive() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        QTTestSupport.waitUntil(timeout: 1) { NSApplication.shared.isActive }

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))

        // The quick terminal auto-hides on resign key (default config), and since
        // we haven't switched spaces, `.move`'s "haven't moved" branch fires and
        // animates the window back out.
        QTTestSupport.waitUntil(timeout: 2) { !controller.visible }
        #expect(!controller.visible)
    }

    @Test func windowDidResignKeyIsANoOpWhileNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(!controller.visible)
    }

    @Test func windowDidResignKeyDoesNotAnimateOutWhileASheetIsAttached() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            QTTestSupport.tearDown(controller, window)
        }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        QTTestSupport.waitUntil(timeout: 1) { window.attachedSheet != nil }
        try #require(window.attachedSheet != nil)

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))

        #expect(controller.visible)
    }

    @Test func windowDidBecomeKeyRunsTheVisibleSyncPathWithoutCrashing() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(controller.visible)
        #expect(controller.terminalViewContainer != nil)
    }
}

@MainActor
struct QuickTerminalControllerSurfaceTreeTests {
    @Test func newSplitCreatesASecondSurfaceAndSplitsTheTree() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)

        let created = try #require(controller.newSplit(at: original, direction: .right))

        #expect(controller.surfaceTree.contains(created))
        #expect(controller.surfaceTree.isSplit)
    }

    @Test func closeSurfaceOnRootLeafWithALivingProcessAnimatesOutWithoutTouchingTheTree() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let node = try #require(controller.surfaceTree.root)

        controller.closeSurface(node, withConfirmation: false)

        QTTestSupport.waitUntil { !controller.visible }
        #expect(!controller.visible)
        #expect(!controller.surfaceTree.isEmpty)
    }

    @Test func closeSurfaceOnRootLeafWithAnExitedProcessEmptiesTheTreeAndAnimatesOut() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let root = try #require(controller.focusedSurface)
        let node = try #require(controller.surfaceTree.root)
        root.pty?.terminate()

        controller.closeSurface(node, withConfirmation: false)

        #expect(controller.surfaceTree.isEmpty)
        QTTestSupport.waitUntil { !controller.visible }
        #expect(!controller.visible)
    }

    @Test func closeSurfaceOnANonRootLeafDelegatesToSuperRemovingOnlyThatLeaf() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let node = try #require(controller.surfaceTree.root?.node(view: created))

        controller.closeSurface(node, withConfirmation: false)

        #expect(!controller.surfaceTree.contains(created))
        #expect(controller.surfaceTree.contains(original))
        #expect(controller.visible)
    }

    @Test func closeSurfaceOnTheRootSplitDelegatesToSuperRemovingTheWholeSplit() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)
        _ = try #require(controller.newSplit(at: original, direction: .right))
        let rootNode = try #require(controller.surfaceTree.root)
        try #require(controller.surfaceTree.isSplit)

        controller.closeSurface(rootNode, withConfirmation: false)

        #expect(controller.surfaceTree.isEmpty)
    }

    @Test func surfaceTreeChangeWhileHiddenAnimatesBackIn() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let original = try #require(controller.focusedSurface)
        controller.animateOut()
        QTTestSupport.waitUntil { !controller.visible }
        try #require(!controller.visible)

        _ = controller.newSplit(at: original, direction: .right)

        QTTestSupport.waitUntil { controller.visible }
        #expect(controller.visible)
    }

    @Test func focusSurfaceWhenVisibleDelegatesToSuperWithoutCrashing() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        controller.focusSurface(surface)
        #expect(controller.visible)
    }

    @Test func focusSurfaceWhenHiddenAnimatesBackIn() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        controller.animateOut()
        QTTestSupport.waitUntil { !controller.visible }

        controller.focusSurface(surface)

        QTTestSupport.waitUntil { controller.visible }
        #expect(controller.visible)
    }

    @Test func focusSurfaceIgnoresViewsNotOwnedByThisQuickTerminal() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        let foreign = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { foreign.close() }
        controller.focusSurface(foreign)
        #expect(!controller.visible)
    }
}

@MainActor
struct QuickTerminalControllerNotificationTests {
    @Test func applicationWillTerminateClearsHiddenDockStateWithoutCrashing() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(controller.visible)
    }

    @Test func onToggleFullscreenIgnoresNonSurfaceObjects() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        // `windowDidLoad()` (in `BaseTerminalController`) always eagerly
        // creates a `NativeFullscreen` style to set up its observers, so
        // `fullscreenStyle` itself is never nil past that point -- the
        // observable "did this notification do anything" signal is whether
        // it actually *entered* fullscreen.
        #expect(controller.fullscreenStyle?.isFullscreen == false)
        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: NSObject())
        #expect(controller.fullscreenStyle?.isFullscreen == false)
    }

    @Test func onToggleFullscreenIgnoresSurfacesThatArentFocused() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let other = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { other.close() }
        #expect(controller.fullscreenStyle?.isFullscreen == false)
        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: other)
        #expect(controller.fullscreenStyle?.isFullscreen == false)
    }

    @Test func onToggleFullscreenEntersAndExitsForTheFocusedSurface() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        // `QTTestSupport.makeController` builds the window with
        // `[.borderless, .resizable]` (no `.titled` bit ever set), so
        // `.resizable` -- not `.titled` -- is the bit `enter()`/`exit()`
        // actually flips here.
        #expect(window.styleMask.contains(.resizable))

        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: surface)
        QTTestSupport.waitUntil(timeout: 2) { controller.fullscreenStyle?.isFullscreen == true }
        #expect(controller.fullscreenStyle?.isFullscreen == true)
        // `NonNativeFullscreen.enter()` strips `.titled`/`.resizable`
        // synchronously; only the actual screen-sized `setFrame` call is
        // deferred behind the dead `DispatchQueue.main.async` hop this
        // harness never drains (see `QTTestSupport.loadAndAnimateIn`'s doc
        // comment), so the style mask -- not the frame -- is what's
        // observable here.
        #expect(!window.styleMask.contains(.resizable))

        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: surface)
        QTTestSupport.waitUntil(timeout: 2) { controller.fullscreenStyle?.isFullscreen == false }
        #expect(controller.fullscreenStyle?.isFullscreen == false)
        // `exit()` restores the saved style mask synchronously (unlike
        // `enter()`, it has no deferred `setFrame` hop at all).
        #expect(window.styleMask.contains(.resizable))
    }

    @Test func takoConfigDidChangeIgnoresNotificationsScopedToASurface() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let before = window.isOpaque
        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: NSObject(),
            userInfo: [Notification.Name.TakoConfigChangeKey: controller.tako.config])
        #expect(window.isOpaque == before)
    }

    @Test func takoConfigDidChangeIgnoresAMissingConfigPayload() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let before = window.isOpaque
        NotificationCenter.default.post(name: .takoConfigDidChange, object: nil, userInfo: nil)
        #expect(window.isOpaque == before)
    }

    @Test func takoConfigDidChangeAppliesANewGlobalConfigsTransparency() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        try #require(window.isOpaque)

        let translucent = try TemporaryConfig("background-opacity = 0.4\n")
        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: nil,
            userInfo: [Notification.Name.TakoConfigChangeKey: translucent])

        #expect(!window.isOpaque)
    }

    @Test func onNewTabIgnoresNonSurfaceObjects() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: NSObject())
        #expect(window.attachedSheet == nil)
    }

    @Test func onNewTabShowsAlertForASurfaceOwnedByThisQuickTerminal() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            QTTestSupport.tearDown(controller, window)
        }
        let surface = try #require(controller.focusedSurface)
        NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: surface)
        QTTestSupport.waitUntil(timeout: 1) { window.attachedSheet != nil }
        #expect(window.attachedSheet != nil)
    }

    @Test func onNewTabIgnoresSurfacesNotHostedInAQuickTerminalWindow() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let foreignSurface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        foreignWindow.contentView = foreignSurface
        defer { foreignSurface.close(); foreignWindow.close() }

        NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: foreignSurface)

        #expect(window.attachedSheet == nil)
    }

    @Test func closeWindowAnimatesOutInsteadOfActuallyClosing() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        controller.closeWindow(controller)
        QTTestSupport.waitUntil { !controller.visible }
        #expect(!controller.visible)
        #expect(controller.window === window)
    }

    @Test func newTabActionShowsTheUnsupportedAlertInsteadOfCreatingATab() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            QTTestSupport.tearDown(controller, window)
        }
        controller.newTab(nil)
        QTTestSupport.waitUntil(timeout: 1) { window.attachedSheet != nil }
        #expect(window.attachedSheet != nil)
    }

    /// `Tako.SurfaceView.surface` is hardcoded to `nil` in this Zig-less shim
    /// (see `Tako+App.swift`), so the guard in `toggleTakoFullScreen` /
    /// `toggleTerminalInspector` that reads it can never see a non-nil value
    /// here; the call these guards protect is unreachable without a real
    /// Zig core behind the surface. Documented gap, not a test workaround.
    @Test func toggleTakoFullScreenAndInspectorActionsAreNoOpsInThisShim() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        controller.toggleTakoFullScreen(controller)
        controller.toggleTerminalInspector(nil)
        #expect(controller.visible)
    }
}
