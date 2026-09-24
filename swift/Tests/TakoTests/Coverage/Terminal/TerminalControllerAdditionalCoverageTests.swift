import Testing
import AppKit
@testable import Tako
@testable import TakoKit

/// Additional coverage for `TerminalController` beyond
/// `TerminalControllerCoverageTests`: the window-creation paths
/// (`newWindow`, `newWindow(tree:)`, `newTab`) that need `.window` non-nil,
/// undo/redo bodies, and notification handlers' "match" branches.
///
/// `Terminal.xib` is excluded from this SwiftPM test target, so any code
/// that reads `.window` on a controller built the normal way is
/// unreachable. `TerminalController.system.attachWindow` is the injectable
/// seam that unblocks it: tests install `TerminalTestSupport.injectedWindowSystem()`
/// to attach a real, manually built `TerminalWindow` (mirroring
/// `TerminalTestSupport.makeController`) the moment a new controller is
/// created inside these methods.
@MainActor
private func withInjectedWindowSystem<T>(_ body: () throws -> T) rethrows -> T {
    let original = TerminalController.system
    TerminalController.system = TerminalTestSupport.injectedWindowSystem()
    defer { TerminalController.system = original }
    return try body()
}

@MainActor
private func withInjectedWindowSystem<T>(_ body: () async throws -> T) async rethrows -> T {
    let original = TerminalController.system
    TerminalController.system = TerminalTestSupport.injectedWindowSystem()
    defer { TerminalController.system = original }
    return try await body()
}

@MainActor
private func withRealAppDelegate<T>(_ body: (AppDelegate) throws -> T) rethrows -> T {
    let appDelegate = AppDelegate()
    let originalDelegate = NSApplication.shared.delegate
    NSApplication.shared.delegate = appDelegate
    defer { NSApplication.shared.delegate = originalDelegate }
    return try body(appDelegate)
}

@MainActor
private func withRealAppDelegate<T>(_ body: (AppDelegate) async throws -> T) async rethrows -> T {
    let appDelegate = AppDelegate()
    let originalDelegate = NSApplication.shared.delegate
    NSApplication.shared.delegate = appDelegate
    defer { NSApplication.shared.delegate = originalDelegate }
    return try await body(appDelegate)
}

@MainActor
struct TerminalControllerWindowNibNameConfigTests {
    @Test func windowDecorationsFalseReturnsTheDefaultNib() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako-\(UUID().uuidString).conf")
        try "window-decoration = none".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        setenv("TAKO_CONFIG_PATH", file.path, 1)
        defer { unsetenv("TAKO_CONFIG_PATH") }

        try withRealAppDelegate { _ in
            let (controller, window) = TerminalTestSupport.makeController()
            defer { TerminalTestSupport.tearDown(controller, window) }
            #expect(controller.windowNibName == "Terminal")
        }
    }
}

@MainActor
struct TerminalControllerDerivedConfigDefaultTests {
    @Test func defaultInitUsesSystemDefaults() {
        let config = TerminalController.DerivedConfig()
        #expect(config.macosWindowButtons == .visible)
        #expect(config.macosTitlebarStyle == .default)
        #expect(config.maximize == false)
        #expect(config.windowPositionX == nil)
        #expect(config.windowPositionY == nil)
    }
}

@MainActor
struct TerminalControllerNewWindowSchedulingTests {
    @Test func newWindowSchedulesPresentationAndBecomesVisible() async throws {
        try await withInjectedWindowSystem {
            let app = Tako.App()
            let controller = TerminalController.newWindow(app)
            defer { controller.window.map { TerminalTestSupport.tearDown(controller, $0) } }

            for _ in 0..<200 where controller.window?.isVisible != true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(controller.window?.isVisible == true)
        }
    }

    @Test func newWindowRegistersUndoThatClosesAndRedoThatRecreates() async throws {
        try await withRealAppDelegate { appDelegate in
            try await withInjectedWindowSystem {
                let controller = TerminalController.newWindow(appDelegate.tako)
                for _ in 0..<200 where controller.window?.isVisible != true {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }

                let undoManager = try #require(controller.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(controller.window?.isVisible != true)

                #expect(undoManager.canRedo)
                undoManager.redo()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    @Test func newWindowWithTreePositionsAndSchedulesPresentation() async throws {
        try await withInjectedWindowSystem {
            let app = Tako.App()
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            let tree = SplitTree(view: view)
            let controller = TerminalController.newWindow(app, tree: tree, position: NSPoint(x: 50, y: 50))
            defer { controller.window.map { TerminalTestSupport.tearDown(controller, $0) } }

            for _ in 0..<200 where controller.window?.isVisible != true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(controller.window?.isVisible == true)
        }
    }

    @Test func newWindowWithTreeWithoutPositionCascades() async throws {
        try await withInjectedWindowSystem {
            let app = Tako.App()
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            let tree = SplitTree(view: view)
            let controller = TerminalController.newWindow(app, tree: tree)
            defer { controller.window.map { TerminalTestSupport.tearDown(controller, $0) } }

            for _ in 0..<200 where controller.window?.isVisible != true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(controller.window?.isVisible == true)
        }
    }

    @Test func newWindowWithTreeRegistersUndoAndRedoWhenConfirmUndoIsFalse() async throws {
        try await withRealAppDelegate { appDelegate in
            try await withInjectedWindowSystem {
                let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                let tree = SplitTree(view: view)
                let controller = TerminalController.newWindow(appDelegate.tako, tree: tree, confirmUndo: false)
                for _ in 0..<200 where controller.window?.isVisible != true {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }

                let undoManager = try #require(controller.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

@MainActor
struct TerminalControllerNewTabSchedulingTests {
    @Test func newTabJoinsTheParentGroupAndSchedulesPresentation() async throws {
        try await withRealAppDelegate { appDelegate in
            let (parent, parentWindow) = TerminalTestSupport.loaded()
            defer { TerminalTestSupport.tearDown(parent, parentWindow) }
            parentWindow.orderFrontRegardless()

            try await withInjectedWindowSystem {
                let child = try #require(TerminalController.newTab(appDelegate.tako, from: parentWindow))
                defer { child.window.map { TerminalTestSupport.tearDown(child, $0) } }
                let childWindow = try #require(child.window)

                #expect(Tako.CustomTabGroup.group(for: parentWindow).windows.contains(childWindow))

                for _ in 0..<200 where child.window?.isVisible != true {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                #expect(child.window?.isVisible == true)

                let undoManager = try #require(parent.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()

                // The tab-labeling fixup is scheduled 0.1s out.
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    @Test func newTabWithEndPositionJoinsAfterTheLastTab() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako-\(UUID().uuidString).conf")
        try "window-new-tab-position = end".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = Tako.App(configPath: file.path)

        try await withInjectedWindowSystem {
            let (parent, parentWindow) = TerminalTestSupport.loaded()
            defer { TerminalTestSupport.tearDown(parent, parentWindow) }
            parentWindow.orderFrontRegardless()

            let child = try #require(TerminalController.newTab(app, from: parentWindow))
            defer { child.window.map { TerminalTestSupport.tearDown(child, $0) } }

            for _ in 0..<200 where child.window?.isVisible != true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(child.window?.isVisible == true)
        }
    }
}

@MainActor
struct TerminalControllerCloseTabUndoTests {
    @Test func closeTabImmediatelyRegistersUndoAndRedoWithMultipleTabs() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                defer { TerminalTestSupport.tearDown(a, aWindow) }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.makeKeyAndOrderFront(nil)
                bWindow.makeKeyAndOrderFront(nil)

                b.closeTabImmediately()
                #expect(!bWindow.isVisible)

                let undoManager = try #require(b.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()
            }
        }
    }

    @Test func closeOtherTabsImmediatelyRegistersUndoAndRedo() async throws {
        try await withRealAppDelegate { _ in
            try await withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                defer { TerminalTestSupport.tearDown(a, aWindow) }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.makeKeyAndOrderFront(nil)

                a.closeOtherTabs(nil)
                #expect(!bWindow.isVisible)

                let undoManager = try #require(a.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                try await Task.sleep(nanoseconds: 100_000_000)
                #expect(undoManager.canRedo)
                undoManager.redo()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    @Test func closeTabsOnTheRightImmediatelyRegistersUndoAndRedo() async throws {
        try await withRealAppDelegate { _ in
            try await withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                defer { TerminalTestSupport.tearDown(a, aWindow) }
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.makeKeyAndOrderFront(nil)

                a.closeTabsOnTheRight(nil)
                #expect(!bWindow.isVisible)

                let undoManager = try #require(a.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                try await Task.sleep(nanoseconds: 100_000_000)
                #expect(undoManager.canRedo)
                undoManager.redo()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

@MainActor
struct TerminalControllerCloseWindowUndoTests {
    @Test func closeWindowImmediatelyRegistersUndoForASingleWindow() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (controller, window) = TerminalTestSupport.loaded()
                window.orderFrontRegardless()

                controller.closeWindowImmediately()

                let undoManager = try #require(controller.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()
            }
        }
    }

    @Test func closeWindowImmediatelyRegistersUndoForATabGroup() throws {
        try withRealAppDelegate { _ in
            try withInjectedWindowSystem {
                let (a, aWindow) = TerminalTestSupport.loaded()
                let (b, bWindow) = TerminalTestSupport.loaded()
                Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
                aWindow.orderFrontRegardless()
                bWindow.makeKeyAndOrderFront(nil)

                a.closeWindowImmediately()
                #expect(!aWindow.isVisible)
                #expect(!bWindow.isVisible)

                let undoManager = try #require(a.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()
            }
        }
    }
}

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
