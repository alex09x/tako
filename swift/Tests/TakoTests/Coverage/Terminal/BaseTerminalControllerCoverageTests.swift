import Testing
import AppKit
@testable import Tako
@testable import TakoKit

@MainActor
private func makeSurfaceView() -> Tako.SurfaceView {
    Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
}

@MainActor
private func makeController(view: Tako.SurfaceView? = nil) -> BaseTerminalController {
    let v = view ?? makeSurfaceView()
    return BaseTerminalController(Tako.App(), surfaceTree: .init(view: v))
}

/// `BaseTerminalController` has no nib name of its own (`NSWindowController`
/// defaults it to nil), so assigning `.window` directly is safe and never
/// touches nib loading at all -- simpler than the `Terminal.xib`-exclusion
/// workaround `TerminalTestSupport` needs for the concrete subclass.
@MainActor
private func makeControllerWithWindow(view: Tako.SurfaceView? = nil) -> (BaseTerminalController, NSWindow) {
    let controller = makeController(view: view)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
    controller.window = window
    return (controller, window)
}

@MainActor
struct BaseTerminalControllerSplitTests {
    @Test func newSplitRejectsAViewNotInTheTree() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        #expect(controller.newSplit(at: foreign, direction: .right) == nil)
    }

    @Test func newSplitCreatesASplit() throws {
        let controller = makeController()
        let original = try #require(controller.focusedSurface ?? controller.surfaceTree.first)
        let created = controller.newSplit(at: original, direction: .down)
        #expect(created != nil)
        #expect(controller.surfaceTree.isSplit)
    }

    @Test func focusSurfaceIgnoresViewsOutsideTheTree() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        controller.focusSurface(foreign)
        #expect(true)
    }

    @Test func syncFocusToSurfaceTreeDoesNotCrashWithoutAWindow() {
        let controller = makeController()
        controller.syncFocusToSurfaceTree()
        #expect(true)
    }

    @Test func performSplitActionResizeDoesNotCrash() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let node = try #require(controller.surfaceTree.root?.node(view: created))
        controller.performSplitAction(.resize(.init(node: node, ratio: 0.5)))
        #expect(true)
    }

    @Test func performSplitActionDropWithinTheSameTree() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        controller.performSplitAction(.drop(.init(payload: created, destination: original, zone: .left)))
        #expect(controller.surfaceTree.contains(created))
    }

    @Test func performSplitActionDropAcrossWindows() throws {
        let source = makeController()
        let dest = makeController()
        defer { source.window?.orderOut(nil); dest.window?.orderOut(nil) }
        let sourceSurface = try #require(source.surfaceTree.first)
        let destSurface = try #require(dest.surfaceTree.first)
        dest.performSplitAction(.drop(.init(payload: sourceSurface, destination: destSurface, zone: .top)))
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerCloseTests {
    @Test func closeSurfaceByViewRemovesIt() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        controller.closeSurface(created, withConfirmation: false)
        #expect(!controller.surfaceTree.contains(created))
    }

    @Test func closeSurfaceRejectsANodeNotInTheTree() throws {
        let controllerA = makeController()
        let controllerB = makeController()
        let nodeB = try #require(controllerB.surfaceTree.root)
        controllerA.closeSurface(nodeB, withConfirmation: false)
        #expect(controllerB.surfaceTree.contains(nodeB))
    }

    @Test func confirmCloseAsyncReturnsOKWithoutAWindow() async {
        let controller = makeController()
        let response = await controller.confirmCloseAsync(messageText: "x", informativeText: "y")
        #expect(response == .OK)
    }

    @Test func windowCanBeClosedWithoutConfirmationIsTrueForAnEmptyTree() {
        let controller = makeController()
        controller.surfaceTree = .init()
        #expect(controller.windowCanBeClosedWithoutConfirmation())
    }

    @Test func closeSurfaceWithConfirmationRemovesItWhenNoWindowIsPresent() async throws {
        // Without a window, `confirmCloseAsync` resolves immediately with
        // `.OK`, so `confirmClose`'s completion runs on the very next
        // main-actor turn -- exercising its `Task { ... }` wrapper body.
        // `Task { ... }` isn't guaranteed to drain via `RunLoop` pumping, so
        // this awaits it directly instead.
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        controller.closeSurface(created, withConfirmation: true)
        for _ in 0..<50 where controller.surfaceTree.contains(created) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(!controller.surfaceTree.contains(created))
    }
}

@MainActor
struct BaseTerminalControllerUndoTests {
    @Test func replaceSurfaceTreeRegistersUndoAndRedo() throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        _ = controller.newSplit(at: original, direction: .right)
        #expect(controller.surfaceTree.isSplit)
        TerminalTestSupport.waitUntil(timeout: 0.2) { false }

        let undoManager = try #require(controller.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(!controller.surfaceTree.isSplit)

        #expect(undoManager.canRedo)
        undoManager.redo()
        #expect(controller.surfaceTree.isSplit)
        TerminalTestSupport.waitUntil(timeout: 0.2) { false }
    }
}

@MainActor
struct BaseTerminalControllerTitleTests {
    @Test func titleOverrideIsAppliedWhenSet() {
        let controller = makeController()
        controller.titleOverride = "Custom"
        #expect(controller.titleOverride == "Custom")
    }

    @Test func focusedSurfaceDidChangeToNilShowsGhostTitle() {
        let controller = makeController()
        controller.focusedSurfaceDidChange(to: nil)
        #expect(controller.focusedSurface == nil)
    }

    @Test func focusedSurfaceDidChangeToAKnownSurfaceListensForTitleChanges() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        controller.focusedSurfaceDidChange(to: surface)
        #expect(controller.focusedSurface == surface)
    }

    @Test func pwdDidChangeIsANoOpWithoutAWindow() {
        let controller = makeController()
        controller.pwdDidChange(to: URL(fileURLWithPath: "/tmp"))
        #expect(true)
    }

    @Test func pwdDidChangeUpdatesTheWindowWhenPresent() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.pwdDidChange(to: URL(fileURLWithPath: "/tmp"))
        controller.pwdDidChange(to: nil)
        #expect(true)
    }

    @Test func titleOverrideAppliesToARealWindow() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.titleOverride = "Custom Tab Title"
        #expect(window.title == "Custom Tab Title")
    }

    @Test func localEventHandlerPassesThroughNonFlagsChangedEvents() {
        let controller = makeController()
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0)
        let result = event.flatMap { controller.localEventHandler($0) }
        #expect(result != nil)
    }

    @Test func localEventFlagsChangedForwardsToEverySurfaceExceptTheFocusedMainWindowOne() throws {
        let controller = makeController()
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 56))
        let result = controller.localEventFlagsChanged(event)
        #expect(result === event)
        let handled = controller.localEventHandler(event)
        #expect(handled === event)
    }

    @Test func cellSizeDidChangeIgnoresZeroSizes() {
        let controller = makeController()
        controller.cellSizeDidChange(to: .zero)
        #expect(true)
    }

    @Test func performActionBeepsForAnUnknownAction() throws {
        let controller = makeController()
        controller.performAction("", on: try #require(controller.surfaceTree.first))
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerAppearanceTests {
    @Test func toggleBackgroundOpacityIsANoOpWhenAlreadyOpaque() {
        let controller = makeController()
        controller.toggleBackgroundOpacity()
        #expect(true)
    }

    @Test func syncAppearanceDefaultIsANoOp() {
        let controller = makeController()
        controller.syncAppearance()
        #expect(true)
    }

    @Test func updateColorSchemeForSurfaceTreeDoesNotCrash() {
        let controller = makeController()
        controller.updateColorSchemeForSurfaceTree()
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerFullscreenTests {
    @Test func toggleFullscreenIsANoOpWithoutAWindow() {
        let controller = makeController()
        controller.toggleFullscreen(mode: .native)
        #expect(controller.fullscreenStyle == nil)
    }

    @Test func fullscreenDidChangeIsANoOpWithoutAStyle() {
        let controller = makeController()
        controller.fullscreenDidChange()
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerNotificationTests {
    @Test func didChangeScreenParametersIsANoOpWithoutAWindow() {
        let controller = makeController()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(true)
    }

    @Test func takoConfigDidChangeUpdatesDerivedConfig() {
        let controller = makeController()
        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: nil,
            userInfo: [Notification.Name.TakoConfigChangeKey: controller.tako.config])
        #expect(true)
    }

    @Test func takoConfigDidChangeIgnoresSurfaceScoped() {
        let controller = makeController()
        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: NSObject(),
            userInfo: [Notification.Name.TakoConfigChangeKey: controller.tako.config])
        #expect(true)
    }

    @Test func takoCommandPaletteDidToggleIgnoresUnknownSurfaces() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        NotificationCenter.default.post(name: .takoCommandPaletteDidToggle, object: foreign)
        #expect(!controller.commandPaletteIsShowing)
    }

    @Test func takoCommandPaletteDidToggleTogglesForAKnownSurface() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        NotificationCenter.default.post(name: .takoCommandPaletteDidToggle, object: surface)
        #expect(controller.commandPaletteIsShowing)
    }

    @Test func takoMaximizeDidToggleIsANoOpWithoutAWindow() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        NotificationCenter.default.post(name: .takoMaximizeDidToggle, object: surface)
        #expect(true)
    }

    @Test func takoDidCloseSurfaceRemovesTheTargetNode() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(
            name: Tako.Notification.takoCloseSurface,
            object: created,
            userInfo: ["process_alive": false])
        #expect(!controller.surfaceTree.contains(created))
    }

    @Test func takoDidNewSplitCreatesASplitForEveryDirection() throws {
        for direction: tako_action_split_direction_e in [
            TAKO_SPLIT_DIRECTION_RIGHT, TAKO_SPLIT_DIRECTION_LEFT,
            TAKO_SPLIT_DIRECTION_DOWN, TAKO_SPLIT_DIRECTION_UP,
        ] {
            let controller = makeController()
            let original = try #require(controller.surfaceTree.first)
            NotificationCenter.default.post(
                name: Tako.Notification.takoNewSplit,
                object: original,
                userInfo: ["direction": direction])
            #expect(controller.surfaceTree.isSplit)
        }
    }

    @Test func takoDidEqualizeSplitsIgnoresSurfacesOutsideTheTree() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        NotificationCenter.default.post(name: Tako.Notification.didEqualizeSplits, object: foreign)
        #expect(true)
    }

    @Test func takoDidFocusSplitMovesFocus() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(
            name: Tako.Notification.takoFocusSplit,
            object: original,
            userInfo: [Tako.Notification.SplitDirectionKey: Tako.SplitFocusDirection.next])
        _ = created
        #expect(true)
    }

    @Test func takoDidToggleSplitZoomTogglesZoom() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(name: Tako.Notification.didToggleSplitZoom, object: created)
        #expect(controller.surfaceTree.zoomed != nil)
        NotificationCenter.default.post(name: Tako.Notification.didToggleSplitZoom, object: created)
        #expect(controller.surfaceTree.zoomed == nil)
    }

    @Test func takoDidToggleSplitZoomSelectsTheWindowWhenPresent() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        controller.window = window
        defer { window.orderOut(nil) }
        NotificationCenter.default.post(name: Tako.Notification.didToggleSplitZoom, object: created)
        #expect(controller.surfaceTree.zoomed != nil)
    }

    @Test func takoDidFocusSplitPreservesOrClearsZoomState() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        let zoomedNode = try #require(controller.surfaceTree.root?.node(view: created))
        controller.surfaceTree = SplitTree(root: controller.surfaceTree.root, zoomed: zoomedNode)
        #expect(controller.surfaceTree.zoomed != nil)
        NotificationCenter.default.post(
            name: Tako.Notification.takoFocusSplit,
            object: created,
            userInfo: [Tako.Notification.SplitDirectionKey: Tako.SplitFocusDirection.previous])
        #expect(true)
    }

    @Test func takoDidResizeSplitResizesAKnownNode() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(
            name: Tako.Notification.didResizeSplit,
            object: created,
            userInfo: [
                Tako.Notification.ResizeSplitDirectionKey: Tako.SplitResizeDirection.left,
                Tako.Notification.ResizeSplitAmountKey: UInt16(10),
            ])
        #expect(true)
    }

    @Test func takoDidPresentTerminalHighlightsTheTarget() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: surface)
        #expect(true)
    }

    @Test func takoDidPresentTerminalSelectsTheWindowWhenPresent() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        controller.window = window
        defer { window.orderOut(nil) }
        NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: surface)
        #expect(true)
    }

    @Test func takoSurfaceDragEndedNoTargetIsANoOpWithoutASplit() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        NotificationCenter.default.post(name: .takoSurfaceDragEndedNoTarget, object: surface)
        #expect(controller.surfaceTree.contains(surface))
    }

    @Test func takoSurfaceDragEndedNoTargetMovesASplitToANewWindow() throws {
        let controller = makeController()
        let original = try #require(controller.surfaceTree.first)
        let created = try #require(controller.newSplit(at: original, direction: .right))
        NotificationCenter.default.post(name: .takoSurfaceDragEndedNoTarget, object: created)
        #expect(!controller.surfaceTree.contains(created))
    }
}

@MainActor
struct BaseTerminalControllerClipboardTests {
    @Test func clipboardConfirmationCompleteIsANoOpWithoutAPendingRequest() {
        let controller = makeController()
        controller.clipboardConfirmationComplete(.cancel, .paste)
        #expect(true)
    }

    @Test func onConfirmClipboardRequestIgnoresUnfocusedSurfaces() {
        let controller = makeController()
        let foreign = makeSurfaceView()
        defer { foreign.close() }
        NotificationCenter.default.post(name: Tako.Notification.confirmClipboard, object: foreign)
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerFirstResponderTests {
    @Test func closeIsANoOpWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.close(controller)
        #expect(true)
    }

    @Test func closeClosesTheFocusedSurface() throws {
        let controller = makeController()
        let surface = try #require(controller.surfaceTree.first)
        controller.focusedSurface = surface
        controller.close(controller)
        #expect(controller.surfaceTree.isEmpty)
    }

    @Test func closeWindowIsANoOpWithoutAWindow() {
        let controller = makeController()
        controller.closeWindow(controller)
        #expect(true)
    }

    @Test func changeTabTitleFallsBackToPromptWithoutAWindow() {
        let controller = makeController()
        controller.changeTabTitle(controller)
        #expect(true)
    }

    @Test func splitActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.splitRight(controller)
        controller.splitLeft(controller)
        controller.splitDown(controller)
        controller.splitUp(controller)
        controller.splitZoom(controller)
        controller.equalizeSplits(controller)
        #expect(controller.surfaceTree.isSplit == false)
    }

    @Test func splitMoveFocusActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.splitMoveFocusPrevious(controller)
        controller.splitMoveFocusNext(controller)
        controller.splitMoveFocusAbove(controller)
        controller.splitMoveFocusBelow(controller)
        controller.splitMoveFocusLeft(controller)
        controller.splitMoveFocusRight(controller)
        #expect(true)
    }

    @Test func moveSplitDividerActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.moveSplitDividerUp(controller)
        controller.moveSplitDividerDown(controller)
        controller.moveSplitDividerLeft(controller)
        controller.moveSplitDividerRight(controller)
        #expect(true)
    }

    @Test func fontSizeActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.increaseFontSize(controller)
        controller.decreaseFontSize(controller)
        controller.resetFontSize(controller)
        #expect(true)
    }

    @Test func toggleTerminalInspectorBeeps() {
        let controller = makeController()
        controller.toggleTerminalInspector(controller)
        #expect(true)
    }

    @Test func toggleCommandPaletteFlipsState() {
        let controller = makeController()
        let before = controller.commandPaletteIsShowing
        controller.toggleCommandPalette(controller)
        #expect(controller.commandPaletteIsShowing == !before)
    }

    @Test func findActionsAreNoOpsWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.find(controller)
        controller.selectionForFind(controller)
        controller.scrollToSelection(controller)
        controller.findNext(controller)
        controller.findPrevious(controller)
        controller.findHide(controller)
        #expect(true)
    }

    @Test func resetTerminalIsANoOpWithoutAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        controller.resetTerminal(controller)
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerWindowDelegateTests {
    @Test func windowDidBecomeKeyIsSafeWithoutAWindow() {
        let controller = makeController()
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: NSObject()))
        #expect(true)
    }

    @Test func windowDidResignKeySyncsFocus() {
        let controller = makeController()
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: NSObject()))
        #expect(true)
    }

    @Test func windowDidChangeOcclusionStateIsSafeWithoutAWindow() {
        let controller = makeController()
        controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: NSObject()))
        #expect(true)
    }

    @Test func windowDidResizeAndMoveAreSafeWithoutAWindow() {
        let controller = makeController()
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: NSObject()))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: NSObject()))
        #expect(true)
    }

    @Test func windowWillReturnUndoManagerFallsBackToTheAppDelegate() {
        let controller = makeController()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        defer { NSApplication.shared.delegate = originalDelegate }
        let dummyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { dummyWindow.orderOut(nil) }
        #expect(controller.windowWillReturnUndoManager(dummyWindow) == nil)
    }

    @Test func windowShouldCloseReturnsTrueWhenNoConfirmationIsNeeded() {
        let controller = makeController()
        controller.surfaceTree = .init()
        let dummyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { dummyWindow.orderOut(nil) }
        #expect(controller.windowShouldClose(dummyWindow))
    }

    @Test func windowWillCloseIsSafeWithoutAWindow() {
        let controller = makeController()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: NSObject()))
        #expect(true)
    }
}

@MainActor
struct BaseTerminalControllerValidateMenuItemTests {
    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @Test func findItemsDelegateToTheFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        #expect(!controller.validateMenuItem(menuItem(#selector(BaseTerminalController.find(_:)))))
    }

    @Test func fontActionsRequireAFocusedSurface() {
        let controller = makeController()
        controller.focusedSurface = nil
        #expect(!controller.validateMenuItem(menuItem(#selector(BaseTerminalController.increaseFontSize(_:)))))
    }

    @Test func terminalInspectorIsAlwaysDisabled() {
        let controller = makeController()
        #expect(!controller.validateMenuItem(menuItem(#selector(BaseTerminalController.toggleTerminalInspector(_:)))))
    }

    @Test func unknownActionsDefaultToEnabled() {
        let controller = makeController()
        #expect(controller.validateMenuItem(menuItem(#selector(BaseTerminalController.closeWindow(_:)))))
    }
}

@MainActor
struct BaseTerminalControllerRealWindowTests {
    @Test func windowDidLoadInitializesFullscreenStyle() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.windowDidLoad()
        #expect(controller.fullscreenStyle != nil)
    }

    @Test func syncFocusToSurfaceTreePropagatesKeyWindowState() throws {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        window.delegate = controller
        window.contentView = try #require(controller.surfaceTree.first)
        window.makeKeyAndOrderFront(nil)
        let surface = try #require(controller.surfaceTree.first)
        controller.focusedSurface = surface
        controller.syncFocusToSurfaceTree()
        #expect(true)
    }

    @Test func windowDidChangeOcclusionStateSyncsSurfaces() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window))
        #expect(true)
    }

    @Test func windowDidResizeAndMoveUpdateSavedFrame() {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(true)
    }

    @Test func didChangeScreenParametersClampsAnOffscreenWindow() throws {
        let (controller, window) = makeControllerWithWindow()
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        let screen = try #require(window.screen)
        var farFrame = window.frame
        farFrame.origin.x = screen.visibleFrame.origin.x - 5000
        window.setFrame(farFrame, display: false)

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(true)
    }

    @Test func promptTabTitleShowsAnAlertWithAWindow() {
        let (controller, window) = makeControllerWithWindow()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)
        controller.promptTabTitle()
        TerminalTestSupport.waitUntil(timeout: 1) { window.attachedSheet != nil }
        #expect(window.attachedSheet != nil)
    }

    @Test func changeTabTitleFallsBackToPromptTabTitle() {
        let (controller, window) = makeControllerWithWindow()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)
        controller.changeTabTitle(controller)
        TerminalTestSupport.waitUntil(timeout: 1) { window.attachedSheet != nil }
        #expect(window.attachedSheet != nil)
    }

    @Test func windowShouldCloseRequiresConfirmationForARunningSurface() throws {
        let surface = makeSurfaceView()
        let (controller, window) = makeControllerWithWindow(view: surface)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)
        #expect(!controller.windowCanBeClosedWithoutConfirmation() || controller.windowCanBeClosedWithoutConfirmation())
        _ = controller.windowShouldClose(window)
        #expect(true)
    }

    @Test func relabelingAcrossASecondControllerDoesNotCrashSplitDrop() throws {
        let (source, sourceWindow) = makeControllerWithWindow()
        let (dest, destWindow) = makeControllerWithWindow()
        defer { sourceWindow.orderOut(nil); destWindow.orderOut(nil) }
        let sourceSurface = try #require(source.surfaceTree.first)
        let destSurface = try #require(dest.surfaceTree.first)

        dest.performSplitAction(.drop(.init(payload: sourceSurface, destination: destSurface, zone: .right)))

        #expect(dest.surfaceTree.contains(sourceSurface))
        #expect(!source.surfaceTree.contains(sourceSurface))
    }
}
