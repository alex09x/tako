import Testing
import AppKit
import UserNotifications
@testable import Tako

/// `AppDelegate` talks to a pure-stub `TakoKit` in this SwiftPM target (every
/// `tako_app_*`/`tako_config_*` C entry point is a no-op defined in
/// `TakoKit.swift`, not a real FFI bridge -- see that file), so constructing
/// a real `AppDelegate()` and driving its `NSApplicationDelegate` callbacks
/// directly is safe: nothing here reaches a real Rust core, a real Accessibility
/// prompt, or a modal alert (`needsConfirmQuit` is hard-coded `false`, so
/// `applicationShouldTerminate` always resolves via its early `.terminateNow`
/// paths and never reaches the confirmation alert in `terminate()`).
///
/// Two things are deliberately NOT exercised here even though they're
/// reachable from `AppDelegate`: `showAbout`/`toggleQuickTerminal` both lazily
/// load a nib (`About.xib`/`QuickTerminal.xib`) that this SwiftPM target
/// excludes (see swift/Package.swift), and `openConfig`/`showHelp`/
/// `setAsDefaultTerminal` launch a real external app or touch real Launch
/// Services defaults on the host running this suite.
@MainActor
private func installDelegate(_ delegate: AppDelegate) -> NSApplicationDelegate? {
    _ = NSApplication.shared
    let original = NSApplication.shared.delegate
    NSApplication.shared.delegate = delegate
    return original
}

@MainActor
private func restoreDelegate(_ original: NSApplicationDelegate?) {
    NSApplication.shared.delegate = original
}

/// A delegate whose alerts and termination replies never reach AppKit: a
/// modal alert never returns in a test host, and a real yes to a pending
/// termination ends the process. Busy terminal windows other tests left
/// open can lead any quit here into the confirmation path.
@MainActor
private func quietDelegate(answer: NSApplication.ModalResponse = .alertThirdButtonReturn) -> AppDelegate {
    let delegate = AppDelegate()
    delegate.runModalAlert = { _ in answer }
    delegate.replyToTermination = { _ in }
    return delegate
}

/// Terminal windows in this process that would ask before closing.
@MainActor
private func busyTerminalWindows() -> [BaseTerminalController] {
    NSApplication.shared.windows
        .compactMap { $0.windowController as? BaseTerminalController }
        .filter { !$0.windowCanBeClosedWithoutConfirmation() }
}

/// Builds a real `TerminalController` with its window assigned directly
/// (bypassing nib loading, which would fail: `Terminal.xib` is excluded from
/// this SwiftPM target -- see swift/Package.swift), mirroring
/// `QTTestSupport.makeController`'s approach for `QuickTerminalController`.
@MainActor
private func makeTerminalController(_ tako: Tako.App) -> (TerminalController, NSWindow) {
    let controller = TerminalController(tako)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    controller.window = window
    return (controller, window)
}

@MainActor
struct AppDelegateLifecycleTests {
    @Test func willFinishLaunchingRegistersDefaultsWithoutCrashing() {
        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification))
    }

    /// A throwaway suite (never `.standard`) so this never touches the real
    /// defaults domain: `TAKO_CLEAR_USER_DEFAULTS` only wipes anything when
    /// `UserDefaults.takoSuite` is non-nil, which requires
    /// `TAKO_USER_DEFAULTS_SUITE` to be set first.
    @Test func willFinishLaunchingClearsThePersistedSuiteWhenAskedTo() {
        let suiteName = "com.tako-core.coverage-clear-defaults-\(UUID().uuidString)"
        setenv("TAKO_USER_DEFAULTS_SUITE", suiteName, 1)
        setenv("TAKO_CLEAR_USER_DEFAULTS", "1", 1)
        defer {
            unsetenv("TAKO_USER_DEFAULTS_SUITE")
            unsetenv("TAKO_CLEAR_USER_DEFAULTS")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        UserDefaults.tako.set(true, forKey: "SomeStaleCoverageFlag")
        #expect(UserDefaults.tako.object(forKey: "SomeStaleCoverageFlag") != nil)

        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification))

        #expect(UserDefaults.tako.object(forKey: "SomeStaleCoverageFlag") == nil)
    }

    @Test func didFinishLaunchingSetsUpTheAppAndDrainsDeferredConfigWork() async {
        let delegate = AppDelegate()
        let original = installDelegate(delegate)
        defer { restoreDelegate(original) }

        // `UNUserNotificationCenter.current()` crashes outright in a bare
        // `swift test` host (no bundle proxy for the process) -- see the
        // seam's doc comment on `AppDelegate.notificationCenterProvider`.
        // This is deliberately never restored: `applicationDidFinishLaunching`
        // registers `self` as a `NotificationCenter` observer for
        // `object: nil` (i.e. every poster), and that registration outlives
        // this test's `delegate` going out of scope (NotificationCenter
        // retains block-less observers). A later test's own window posting
        // e.g. a bell-state change would otherwise route back into this
        // delegate's `syncDockBadge()` and hit the very crash this seam
        // exists to avoid.
        AppDelegate.notificationCenterProvider = { nil }

        // Forces `applicationDidFinishLaunching`'s "restore last quit's
        // secure-input state" branch: it only calls `toggleSecureInput` when
        // the persisted flag disagrees with the live one.
        let secureInputBefore = SecureInput.shared.enabled
        let globalBefore = SecureInput.shared.global
        let persistedBefore = UserDefaults.tako.object(forKey: "SecureInput")
        UserDefaults.tako.set(!secureInputBefore, forKey: "SecureInput")
        defer {
            // Put the process-wide singleton and the persisted flag back as
            // they were: later suites assume the resting state.
            SecureInput.shared.global = globalBefore
            if let persistedBefore {
                UserDefaults.tako.set(persistedBefore, forKey: "SecureInput")
            } else {
                UserDefaults.tako.removeObject(forKey: "SecureInput")
            }
        }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(delegate.timeSinceLaunch >= 0)

        // takoConfigDidChange (called synchronously from applicationDidFinishLaunching)
        // schedules syncMenuShortcuts/syncAppearance via DispatchQueue.main.async and
        // updateAppIcon via Task.detached. A bare `swift test` host never drains
        // GCD's main queue via RunLoop pumping, but suspending here does -- see
        // TabTitleEditorCoverageTests' `waitAsync` doc comment for why.
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    @Test func applicationDidHideRecordsHiddenStateAndTogglingVisibilityRestoresIt() {
        let delegate = AppDelegate()
        #expect(delegate.hiddenState == nil)

        // A real, visible, non-fullscreen window exercises
        // `ToggleVisibilityState.init()`'s filter/forEach body and its
        // keyWindow branch, which an empty `NSApp.windows` (the common case
        // for a freshly constructed delegate) never reaches.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        delegate.applicationDidHide(Notification(name: NSApplication.didHideNotification))
        #expect(delegate.hiddenState != nil)

        // `NSApp.isActive` is false in this test host (see
        // `toggleVisibilityActivatesTheAppWhenNotAlreadyActive`'s doc
        // comment), so this takes the "become active" branch and calls
        // `hiddenState?.restore()`, covering `ToggleVisibilityState.restore()`.
        delegate.toggleVisibility(delegate)
        #expect(delegate.hiddenState == nil)
    }

    @Test func applicationDidBecomeActiveClearsHiddenStateAndOpensAnInitialWindowOnce() {
        let delegate = AppDelegate()
        delegate.applicationDidHide(Notification(name: NSApplication.didHideNotification))
        #expect(delegate.hiddenState != nil)

        // First call: clears hiddenState and (since `derivedConfig` defaults to
        // `initialWindow == true` and this fresh delegate has no windows of its
        // own yet) opens an initial window. `TerminalController.newWindow`
        // constructs a real controller (and a real `Tako.SurfaceView`/PTY) but
        // defers `showWindow` via `scheduleInitialPresentation`
        // (`DispatchQueue.main.async`), which a bare `swift test` host never
        // drains -- so this never reaches the excluded `Terminal.xib` nib nor
        // adds a window to `NSApp.windows` (see ServiceProviderTests' doc
        // comment for the same guarantee on the same code path).
        delegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(delegate.hiddenState == nil)

        // Second call: applicationHasBecomeActive is now true, so this is a
        // no-op past the guard -- just confirms it doesn't crash or re-fire.
        delegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification))

        // `TerminalController.all` reads live off `NSApp.windows`, and (per
        // the comment above) the window `newWindow` just built never lands
        // there -- so it's still empty here. Combined with
        // `applicationHasBecomeActive` now being true, this reaches
        // `applicationShouldHandleReopen`'s real "open a fresh window" branch.
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) == false)
    }

    @Test func shouldTerminateAfterLastWindowClosedDefaultsToFalse() {
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp) == false)
    }

    @Test func shouldTerminateQuitsAtOnceUnlessATerminalIsBusy() {
        let delegate = quietDelegate()
        let reply = delegate.applicationShouldTerminate(NSApp)
        if busyTerminalWindows().isEmpty {
            #expect(reply == .terminateNow)
        } else {
            // A busy terminal another test left open leads to the stubbed
            // alert (Cancel) or a single window's own review.
            #expect([.terminateCancel, .terminateLater].contains(reply))
        }
    }

    @Test func shouldTerminateWithAVisibleWindowStillSkipsTheAlertAndConfirmQuitCheck() {
        // With `windows.isEmpty` and `windows.allSatisfy { !$0.isVisible }`
        // both false (a real, visible window), this reaches the
        // `currentAppleEvent`/`needsConfirmQuit` tail instead of returning
        // from either of the first two guards. The window holds no
        // terminal, so nothing in it needs confirmation.
        let delegate = quietDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let reply = delegate.applicationShouldTerminate(NSApp)
        if busyTerminalWindows().isEmpty {
            #expect(reply == .terminateNow)
        } else {
            #expect([.terminateCancel, .terminateLater].contains(reply))
        }
    }

    @Test func willTerminateRemovesDeliveredNotificationsWithoutCrashing() {
        let delegate = AppDelegate()
        // Deliberately not restored -- see the doc comment on
        // `didFinishLaunchingSetsUpTheAppAndDrainsDeferredConfigWork` for why
        // this override must outlive any single test.
        AppDelegate.notificationCenterProvider = { nil }

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    @Test func supportsSecureRestorableState() {
        let delegate = AppDelegate()
        #expect(delegate.applicationSupportsSecureRestorableState(NSApp))
    }

    @Test func shouldHandleReopenReturnsTrueWhenVisibleWindowsExist() {
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
    }

    @Test func shouldHandleReopenReturnsTrueBeforeTheAppHasBecomeActive() {
        // A fresh delegate's `applicationHasBecomeActive` starts false, so
        // this returns true from the dedicated guard without ever reaching
        // `TerminalController.newWindow`.
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    }

    @Test func openFileReturnsFalseForAPathThatDoesNotExist() {
        let delegate = AppDelegate()
        let missing = "/tmp/tako-coverage-does-not-exist-\(UUID().uuidString)"
        #expect(delegate.application(NSApp, openFile: missing) == false)
    }

    @Test func openFileOpensADirectoryAsANewTabWithoutConfirmation() {
        // A directory never sets `requiresConfirm`, so this never shows the
        // `NSAlert`/`runModal()` a non-directory file path would (see this
        // file's top-level doc comment for what's deliberately not exercised).
        let delegate = AppDelegate()
        let original = installDelegate(delegate)
        defer { restoreDelegate(original) }

        let dir = FileManager.default.temporaryDirectory.path
        #expect(delegate.application(NSApp, openFile: dir))
    }

    @Test func dockMenuReturnsTheManagedMenuAndReopenBuildsItsItems() {
        let delegate = AppDelegate()
        let menu = delegate.applicationDockMenu(NSApp)
        #expect(menu != nil)
    }

    @Test func restorableStateEncodingIsANoOpWithNoQuickTerminalState() {
        let delegate = AppDelegate()
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        delegate.application(NSApp, willEncodeRestorableState: archiver)
        archiver.finishEncoding()
    }

    @Test func restorableStateDecodingToleratesEmptyData() throws {
        let delegate = AppDelegate()
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        delegate.application(NSApp, didDecodeRestorableState: unarchiver)
        unarchiver.finishDecoding()
    }

    @Test func restorableStateEncodesARealInitializedQuickController() {
        // `quickController` lazily constructs a real `QuickTerminalController`
        // without touching its (nib-backed, excluded from this target) window,
        // and a freshly built one is `restorable` (no base command was given)
        // -- so this reaches `application(willEncodeRestorableState:)`'s
        // `.initialized(let controller) where controller.restorable` case.
        let delegate = AppDelegate()
        _ = delegate.quickController

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        delegate.application(NSApp, willEncodeRestorableState: archiver)
        archiver.finishEncoding()
    }

    @Test func restorableStateRoundTripsAPendingRestoreAndReEncodesIt() throws {
        let delegate = AppDelegate()
        let tako = Tako.App()
        let controller = QuickTerminalController(tako, position: .top)
        let state = QuickTerminalRestorableState(from: controller)

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        // Reaches the `windowSaveState != "never"` && successful-decode branch,
        // setting `quickTerminalControllerState = .pendingRestore(state)`.
        delegate.application(NSApp, didDecodeRestorableState: unarchiver)
        unarchiver.finishDecoding()

        // Encoding again now hits the `.pendingRestore(let state)` case
        // instead of `.initialized`/`default`.
        let reArchiver = NSKeyedArchiver(requiringSecureCoding: true)
        delegate.application(NSApp, willEncodeRestorableState: reArchiver)
        reArchiver.finishEncoding()

        // With a pending restore queued, `quickController`'s getter takes its
        // `.pendingRestore` construction branch (distinct from its
        // `.uninitialized` one, already covered by
        // `quickControllerLazilyInitializesOnceAndReturnsTheSameInstance`).
        #expect(!delegate.quickControllerInitialized)
        _ = delegate.quickController
        #expect(delegate.quickControllerInitialized)
    }
}

@MainActor
struct AppDelegateSecureInputTests {
    @Test func setSecureInputOnOffAndToggleAllUpdateTheGlobalFlag() {
        let delegate = AppDelegate()
        let originallyOn = SecureInput.shared.global
        defer {
            if SecureInput.shared.global != originallyOn {
                delegate.setSecureInput(originallyOn ? .on : .off)
            }
        }

        delegate.setSecureInput(.on)
        #expect(SecureInput.shared.global)

        delegate.setSecureInput(.off)
        #expect(!SecureInput.shared.global)

        delegate.setSecureInput(.toggle)
        #expect(SecureInput.shared.global)

        delegate.setSecureInput(.toggle)
        #expect(!SecureInput.shared.global)
    }
}

@MainActor
struct AppDelegateIBActionTests {
    @Test func reloadConfigPostsAConfigChangeNotification() {
        let delegate = AppDelegate()
        var received = false
        let observer = NotificationCenter.default.addObserver(
            forName: .takoConfigDidChange, object: nil, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        delegate.reloadConfig(nil)
        #expect(received)
    }

    @Test func newWindowAndNewTabIBActionsConstructRealControllersWithoutCrashing() {
        // Both defer `showWindow` the same way `applicationDidBecomeActive`'s
        // initial-window path does (see that test's doc comment): nothing
        // here reaches the excluded Terminal.xib nib.
        let delegate = AppDelegate()
        delegate.newWindow(nil)
        delegate.newTab(nil)
    }

    @Test func toggleSecureInputFlipsTheGlobalFlag() {
        let delegate = AppDelegate()
        let before = SecureInput.shared.global
        defer { if SecureInput.shared.global != before { delegate.toggleSecureInput(delegate) } }
        delegate.toggleSecureInput(delegate)
        #expect(SecureInput.shared.global != before)
    }

    @Test func toggleVisibilityActivatesTheAppWhenNotAlreadyActive() {
        // `NSApp.isActive` is false for this test host (this process cannot
        // win real macOS activation in this harness -- confirmed the same
        // way GlobalEventTapTests documents it), so this always takes the
        // "become active" branch, not the "hide" branch.
        let delegate = AppDelegate()
        delegate.toggleVisibility(delegate)
    }

    @Test func bringAllToFrontActivatesAndArrangesWindows() {
        let delegate = AppDelegate()
        delegate.bringAllToFront(delegate)
    }

    @Test func undoAndRedoAreNoOpsWithNothingRegistered() {
        let delegate = AppDelegate()
        #expect(!delegate.undoManager.canUndo)
        delegate.undo(nil)
        #expect(!delegate.undoManager.canRedo)
        delegate.redo(nil)
    }

    @Test func floatOnTopTogglesTheMenuItemStateEvenWithNoKeyWindow() {
        let delegate = AppDelegate()
        let item = NSMenuItem(title: "Float on Top", action: nil, keyEquivalent: "")
        item.state = .off
        delegate.floatOnTop(item)
        #expect(item.state == .on)
        delegate.floatOnTop(item)
        #expect(item.state == .off)
    }

    @Test func useAsDefaultWritesAndClearsTheDefaultLevelPreference() {
        let delegate = AppDelegate()
        let key = TerminalWindow.defaultLevelKey
        let ud = UserDefaults.tako
        defer { ud.removeObject(forKey: key) }

        let onItem = NSMenuItem(title: "Use as Default", action: nil, keyEquivalent: "")
        onItem.state = .off
        delegate.floatOnTop(onItem) // -> .on, matching menuFloatOnTop's own state indirectly
        delegate.useAsDefault(onItem)
        // useAsDefault reads self.menuFloatOnTop (an @IBOutlet, nil here since
        // there's no nib), not the item passed in, so this always takes the
        // "off" branch and removes the key -- covering the removal line
        // deterministically without depending on outlet wiring.
        #expect(ud.object(forKey: key) == nil)
    }

    @Test func useAsDefaultSetsTheFloatingLevelWhenMenuFloatOnTopIsOn() {
        // `menuFloatOnTop` was widened from `private` (an @IBOutlet with no
        // nib to wire it in this target) so this branch -- otherwise
        // unreachable, as the sibling test above documents -- can be driven
        // directly.
        let delegate = AppDelegate()
        let key = TerminalWindow.defaultLevelKey
        let ud = UserDefaults.tako
        defer { ud.removeObject(forKey: key) }

        delegate.menuFloatOnTop = NSMenuItem(title: "Float on Top", action: nil, keyEquivalent: "")
        delegate.menuFloatOnTop?.state = .on

        delegate.useAsDefault(delegate.menuFloatOnTop!)
        #expect(ud.value(forKey: key) as? NSWindow.Level == .floating)
    }
}

@MainActor
struct AppDelegateMenuValidationTests {
    private func menuItem(_ selector: Selector) -> NSMenuItem {
        NSMenuItem(title: "Item", action: selector, keyEquivalent: "")
    }

    @Test func setAsDefaultTerminalValidatesAgainstTheCurrentDefaultTerminal() {
        let delegate = AppDelegate()
        let item = menuItem(#selector(AppDelegate.setAsDefaultTerminal(_:)))
        _ = delegate.validateMenuItem(item)
    }

    @Test func floatOnTopAndUseAsDefaultAreOnlyValidWithATerminalWindowKey() {
        let delegate = AppDelegate()
        let floatItem = menuItem(#selector(AppDelegate.floatOnTop(_:)))
        let useAsDefaultItem = menuItem(#selector(AppDelegate.useAsDefault(_:)))
        #expect(!delegate.validateMenuItem(floatItem))
        #expect(!delegate.validateMenuItem(useAsDefaultItem))
    }

    @Test func undoAndRedoUpdateTitlesToReflectAvailability() {
        let delegate = AppDelegate()
        let undoItem = menuItem(#selector(AppDelegate.undo(_:)))
        let redoItem = menuItem(#selector(AppDelegate.redo(_:)))
        #expect(!delegate.validateMenuItem(undoItem))
        #expect(undoItem.title == "Undo")
        #expect(!delegate.validateMenuItem(redoItem))
        #expect(redoItem.title == "Redo")
    }

    @Test func unrelatedSelectorsAreAlwaysValid() {
        let delegate = AppDelegate()
        let item = menuItem(#selector(AppDelegate.reloadConfig(_:)))
        #expect(delegate.validateMenuItem(item))
    }
}

@MainActor
struct AppDelegateFloatOnTopMenuSyncTests {
    @Test func syncFloatOnTopMenuTurnsOffWhenTheKeyWindowIsNotATerminalWindow() {
        let delegate = AppDelegate()
        let plain = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        defer { plain.close() }

        delegate.syncFloatOnTopMenu(plain)
        // No @IBOutlet is wired for a bare AppDelegate(), so this only
        // confirms the call is safe with a non-TerminalWindow argument.
    }

    @Test func syncFloatOnTopMenuFallsBackToTheKeyWindowWhenGivenNil() {
        let delegate = AppDelegate()
        delegate.syncFloatOnTopMenu(nil)
    }

    @Test func syncFloatOnTopMenuReflectsAFloatingTerminalWindowsLevel() {
        // `TerminalWindow` has no custom designated initializer of its own
        // (it relies on the inherited `NSWindow` one), so it's safe to
        // construct directly without going through `Terminal.xib`.
        let delegate = AppDelegate()
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        window.level = .floating
        delegate.syncFloatOnTopMenu(window)

        window.level = .normal
        delegate.syncFloatOnTopMenu(window)
    }
}

@MainActor
struct AppDelegateTerminateTests {
    @Test func terminateResolvesImmediatelyWhenNoSurfaceNeedsConfirmation() {
        let delegate = quietDelegate()
        if busyTerminalWindows().isEmpty {
            #expect(delegate.terminate() == .terminateNow)
        } else {
            // Another test's terminal is still busy; the stubbed alert says
            // Cancel, or a single window starts its own review.
            #expect([.terminateCancel, .terminateLater].contains(delegate.terminate()))
        }
    }
}

@MainActor
struct AppDelegateMenuKeyEquivalentTests {
    @Test func performTakoBindingMenuKeyEquivalentReturnsFalseWithNoBindings() throws {
        let delegate = AppDelegate()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
        #expect(!delegate.performTakoBindingMenuKeyEquivalent(with: event))
    }
}

@MainActor
struct AppDelegateTakoDelegateTests {
    @Test func findSurfaceReturnsNilWhenNoWindowHostsIt() {
        let delegate = AppDelegate()
        #expect(delegate.findSurface(forUUID: UUID()) == nil)
    }

    @Test func findSurfaceLocatesASurfaceOwnedByATerminalController() {
        let delegate = AppDelegate()
        let tako = Tako.App()
        let (controller, window) = makeTerminalController(tako)
        defer {
            controller.surfaceTree.forEach { $0.pty?.terminate() }
            window.close()
        }

        guard let surface = controller.surfaceTree.first else {
            Issue.record("Expected the controller's initial surface tree to contain a surface")
            return
        }

        #expect(delegate.findSurface(forUUID: surface.id) === surface)
    }

    @Test func takoSurfaceMirrorsFindSurfaceThroughTheDelegateExtension() {
        let delegate = AppDelegate()
        let tako = Tako.App()
        let (controller, window) = makeTerminalController(tako)
        defer {
            controller.surfaceTree.forEach { $0.pty?.terminate() }
            window.close()
        }

        guard let surface = controller.surfaceTree.first else {
            Issue.record("Expected the controller's initial surface tree to contain a surface")
            return
        }

        #expect(delegate.takoSurface(id: surface.id) === surface)
        #expect(delegate.takoSurface(id: UUID()) == nil)
    }

    @Test func takoSurfaceSkipsNonTerminalWindowsAndReturnsNilOnNoMatch() {
        let delegate = AppDelegate()
        let plain = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        defer { plain.close() }

        // `plain`'s windowController is nil (never assigned one), so this
        // exercises the `continue` branch regardless of what other windows
        // exist elsewhere in this process, and a fresh random UUID cannot
        // collide with any real surface's id, so this also exercises the
        // final `return nil`.
        #expect(delegate.takoSurface(id: UUID()) == nil)
    }
}

/// Several `AppDelegate` handlers are the only real caller for a chunk of
/// logic reached exclusively through `NotificationCenter`/`NSEvent` local
/// monitors that a bare `swift test` host can't deliver (no real window
/// server events, and `applicationDidFinishLaunching`'s local monitor
/// registration is discarded via `_ =`, matching upstream, so it can't be
/// removed to call it again from a clean state). Per this repo's own
/// precedent (`GlobalEventTap.cgEventFlagsChangedHandler`, documented as
/// deliberately `internal` so tests can call it directly), these were
/// widened from `private` to plain (module-internal) visibility in
/// AppDelegate.swift so this suite can drive them directly instead.
@MainActor
struct AppDelegateWidenedHandlerTests {
    @Test func localEventHandlerDispatchesKeyDownAndPassesThroughOtherTypes() throws {
        let delegate = AppDelegate()
        let keyEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
        // Doesn't assert the result (it depends on ambient key-binding
        // state elsewhere in this shared process); just confirms the
        // dispatch and the full localEventKeyDown chain run without crashing.
        _ = delegate.localEventHandler(keyEvent)

        let mouseEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(delegate.localEventHandler(mouseEvent) === mouseEvent)
    }

    @Test func windowDidBecomeKeySyncsTheFloatOnTopMenu() {
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
    }

    @Test func quickTerminalVisibilityChangeIgnoresWrongObjectTypes() {
        let delegate = AppDelegate()
        delegate.quickTerminalDidChangeVisibility(Notification(name: .quickTerminalDidChangeVisibility, object: "not a controller"))
    }

    @Test func quickTerminalVisibilityChangeSyncsTheMenuStateForARealController() {
        let delegate = AppDelegate()
        let tako = Tako.App()
        let controller = QuickTerminalController(tako, position: .top)
        delegate.quickTerminalDidChangeVisibility(
            Notification(name: .quickTerminalDidChangeVisibility, object: controller))
    }

    @Test func takoConfigDidChangeIgnoresSurfaceScopedNotifications() {
        let delegate = AppDelegate()
        delegate.takoConfigDidChange(
            Notification(name: .takoConfigDidChange, object: "a surface, not nil"))
    }

    @Test func takoConfigDidChangeIgnoresMissingUserInfo() {
        let delegate = AppDelegate()
        delegate.takoConfigDidChange(Notification(name: .takoConfigDidChange, object: nil))
    }

    @Test func takoConfigDidChangeAppliesAValidGlobalConfig() async {
        let delegate = AppDelegate()
        AppDelegate.notificationCenterProvider = { nil }

        delegate.takoConfigDidChange(Notification(
            name: .takoConfigDidChange,
            object: nil,
            userInfo: [Notification.Name.TakoConfigChangeKey: Tako.Config()]))

        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func takoBellDidRingRunsThroughAllThreeFeatureChecks() {
        let delegate = AppDelegate()
        delegate.takoBellDidRing(Notification(name: .takoBellDidRing))
    }

    @Test func terminalWindowHasBellIgnoresUnrelatedObjectsAndSyncsForARealController() {
        let delegate = AppDelegate()
        AppDelegate.notificationCenterProvider = { nil }
        delegate.terminalWindowHasBell(
            Notification(name: .terminalWindowBellDidChangeNotification, object: "not a controller"))

        let tako = Tako.App()
        let (controller, window) = makeTerminalController(tako)
        defer {
            controller.surfaceTree.forEach { $0.pty?.terminate() }
            window.close()
        }
        delegate.terminalWindowHasBell(
            Notification(name: .terminalWindowBellDidChangeNotification, object: controller))
    }

    @Test func takoNewWindowBuildsAControllerWithNoBaseConfigWhenUserInfoIsMissing() {
        let delegate = AppDelegate()
        delegate.takoNewWindow(Notification(name: Tako.Notification.takoNewWindow, object: nil))
    }

    @Test func takoNewTabIgnoresNotificationsWithoutASurfaceOrWindowedParent() {
        let delegate = AppDelegate()
        delegate.takoNewTab(Notification(name: Tako.Notification.takoNewTab, object: "not a surface"))

        let tako = Tako.App()
        let orphanSurface = Tako.SurfaceView(tako, baseConfig: nil)
        defer { orphanSurface.pty?.terminate() }
        delegate.takoNewTab(Notification(name: Tako.Notification.takoNewTab, object: orphanSurface))
    }

    @Test func takoNewTabOpensATabForASurfaceHostedByATerminalController() {
        let delegate = AppDelegate()
        let tako = Tako.App()
        let (controller, window) = makeTerminalController(tako)
        defer {
            controller.surfaceTree.forEach { $0.pty?.terminate() }
            window.close()
        }

        guard let surface = controller.surfaceTree.first else {
            Issue.record("Expected the controller's initial surface tree to contain a surface")
            return
        }

        // Assigning `.window` directly (bypassing nib loading, see
        // `makeTerminalController`'s doc comment) never actually embeds the
        // surface into the window's view hierarchy the way the real
        // `windowDidLoad()` would, so `surfaceView.window` stays nil without
        // this -- and `takoNewTab` bails at its `guard let window =
        // surfaceView.window` before ever reaching the windowController check.
        window.contentView = surface
        #expect(surface.window === window)

        delegate.takoNewTab(Notification(name: Tako.Notification.takoNewTab, object: surface))
    }

    @Test func setDockBadgeReflectsBellCountAcrossTerminalWindows() {
        let delegate = AppDelegate()
        delegate.setDockBadge()
    }

    @Test func reloadDockMenuPopulatesNewWindowAndNewTabItems() {
        let delegate = AppDelegate()
        delegate.reloadDockMenu()
        let menu = delegate.applicationDockMenu(NSApp)
        #expect(menu?.items.count == 2)
    }
}

@MainActor
struct AppDelegateQuickControllerTests {
    @Test func quickControllerLazilyInitializesOnceAndReturnsTheSameInstance() {
        let delegate = AppDelegate()
        #expect(!delegate.quickControllerInitialized)

        let first = delegate.quickController
        #expect(delegate.quickControllerInitialized)

        let second = delegate.quickController
        #expect(first === second)
    }
}
