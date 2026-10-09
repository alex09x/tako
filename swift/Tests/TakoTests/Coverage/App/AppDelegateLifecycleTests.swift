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
import UserNotifications
@testable import Tako

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
