import Testing
import Foundation
import AppKit
@testable import Tako

@MainActor
private final class FullscreenDelegateSpy: FullscreenDelegate {
    var changeCount = 0
    func fullscreenDidChange() { changeCount += 1 }
}

@MainActor
private func makeFullscreenTestWindow(at offset: CGFloat = 0) -> NSWindow {
    let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
    let window = NSWindow(
        contentRect: NSRect(x: frame.minX + 20 + offset, y: frame.minY + 20, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .preferred
    return window
}

@MainActor
private func waitFullscreen(timeout: TimeInterval = 3, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

/// Waits by suspending rather than spinning the run loop: these tests run as
/// jobs on the main queue, so work the code under test schedules with
/// `DispatchQueue.main.async` only runs once the test yields the thread.
@MainActor
private func waitAsync(timeout: TimeInterval = 4, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

// MARK: FullscreenMode dispatch

@MainActor
struct FullscreenModeTests {
    @Test func styleForEachModeProducesTheMatchingConcreteType() {
        let window = makeFullscreenTestWindow()
        defer { window.close() }

        #expect(FullscreenMode.native.style(for: window) is NativeFullscreen)
        #expect(FullscreenMode.nonNative.style(for: window) is NonNativeFullscreen)
        #expect(FullscreenMode.nonNativeVisibleMenu.style(for: window) is NonNativeFullscreenVisibleMenu)
        #expect(FullscreenMode.nonNativePaddedNotch.style(for: window) is NonNativeFullscreenPaddedNotch)
    }

    @Test func modeIsCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(FullscreenMode.nonNativeVisibleMenu)
        let decoded = try JSONDecoder().decode(FullscreenMode.self, from: encoded)
        #expect(decoded == .nonNativeVisibleMenu)
    }
}

// MARK: FullscreenBase notification forwarding

@MainActor
struct FullscreenBaseNotificationTests {
    @Test func windowFullscreenNotificationsForwardToDelegateAndPostAppNotifications() {
        let window = makeFullscreenTestWindow()
        defer { window.close() }

        guard let style = NonNativeFullscreen(window) else {
            Issue.record("Expected NonNativeFullscreen to initialize")
            return
        }
        let spy = FullscreenDelegateSpy()
        style.delegate = spy

        var sawEnter = false
        var sawExit = false
        let enterToken = NotificationCenter.default.addObserver(forName: .fullscreenDidEnter, object: style, queue: nil) { _ in sawEnter = true }
        let exitToken = NotificationCenter.default.addObserver(forName: .fullscreenDidExit, object: style, queue: nil) { _ in sawExit = true }
        defer {
            NotificationCenter.default.removeObserver(enterToken)
            NotificationCenter.default.removeObserver(exitToken)
        }

        // FullscreenBase listens for the *real* NSWindow notifications on
        // this specific window object, independent of which concrete style
        // drives the transition -- posting them directly exercises that
        // forwarding logic without needing an actual native Space switch.
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(spy.changeCount == 1)
        #expect(sawEnter)

        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        #expect(spy.changeCount == 2)
        #expect(sawExit)
    }
}

// MARK: NativeFullscreen (guard branches only -- real Space transitions are avoided)

@MainActor
struct NativeFullscreenTests {
    @Test func reportsNativeModeAndTabSupport() {
        let window = makeFullscreenTestWindow()
        defer { window.close() }
        guard let style = NativeFullscreen(window) else {
            Issue.record("Expected NativeFullscreen to initialize")
            return
        }
        #expect(style.fullscreenMode == .native)
        #expect(style.supportsTabs)
    }

    @Test func isFullscreenIsFalseForAnOrdinaryWindow() {
        // AppKit raises an NSException if `.fullScreen` is inserted into
        // styleMask directly outside of a real `toggleFullScreen` transition
        // (confirmed live), so the true branch can only be exercised by an
        // actual native Space transition -- too disruptive to trigger here.
        let window = makeFullscreenTestWindow()
        defer { window.close() }
        guard let style = NativeFullscreen(window) else {
            Issue.record("Expected NativeFullscreen to initialize")
            return
        }
        #expect(!style.isFullscreen)
    }

    @Test func exitIsANoOpWhenNotFullscreen() {
        let window = makeFullscreenTestWindow()
        defer { window.close() }
        guard let style = NativeFullscreen(window) else {
            Issue.record("Expected NativeFullscreen to initialize")
            return
        }
        let separatorBefore = window.titlebarSeparatorStyle
        style.exit()
        #expect(window.titlebarSeparatorStyle == separatorBefore)
    }
}

// MARK: NonNativeFullscreen

@MainActor
struct NonNativeFullscreenTests {
    @Test func propertiesDefaultToHidingMenuAndNoPaddedNotch() {
        let window = makeFullscreenTestWindow()
        defer { window.close() }
        guard let style = NonNativeFullscreen(window) else {
            Issue.record("Expected NonNativeFullscreen to initialize")
            return
        }
        #expect(style.fullscreenMode == .nonNative)
        #expect(!style.supportsTabs)
        #expect(style.properties.hideMenu)
        #expect(!style.properties.paddedNotch)
        #expect(!style.isFullscreen)
    }

    @Test func visibleMenuVariantKeepsMenuBarVisible() {
        let window = makeFullscreenTestWindow()
        defer { window.close() }
        guard let style = NonNativeFullscreenVisibleMenu(window) else {
            Issue.record("Expected NonNativeFullscreenVisibleMenu to initialize")
            return
        }
        #expect(style.fullscreenMode == .nonNativeVisibleMenu)
        #expect(!style.properties.hideMenu)
    }

    @Test func paddedNotchVariantSetsPaddedNotchFlag() {
        let window = makeFullscreenTestWindow()
        defer { window.close() }
        guard let style = NonNativeFullscreenPaddedNotch(window) else {
            Issue.record("Expected NonNativeFullscreenPaddedNotch to initialize")
            return
        }
        #expect(style.fullscreenMode == .nonNativePaddedNotch)
        #expect(style.properties.paddedNotch)
    }

    @Test func enterAndExitRoundTripRestoresOriginalWindowState() async {
        let window = makeFullscreenTestWindow()
        defer { window.close() }
        window.orderFrontRegardless()
        waitFullscreen { window.windowNumber > 0 }

        guard let style = NonNativeFullscreen(window) else {
            Issue.record("Expected NonNativeFullscreen to initialize")
            return
        }
        let spy = FullscreenDelegateSpy()
        style.delegate = spy

        let originalStyleMask = window.styleMask
        let originalFrame = window.frame

        style.enter()
        #expect(style.isFullscreen)
        #expect(!window.styleMask.contains(.titled))
        #expect(!window.styleMask.contains(.resizable))
        // The delegate hears about the change from a deferred main-queue block.
        await waitAsync { spy.changeCount >= 1 }
        #expect(spy.changeCount >= 1)

        // The fullscreen frame assignment happens on a deferred main-queue
        // block; wait for it to actually land before exiting, otherwise it
        // can race with (and clobber) exit()'s own frame restoration below.
        await waitAsync { window.frame != originalFrame }

        style.exit()

        #expect(!style.isFullscreen)
        #expect(window.styleMask == originalStyleMask)
        #expect(window.frame == originalFrame)
        await waitAsync { spy.changeCount >= 2 }
        #expect(spy.changeCount >= 2)
    }

    @Test func windowWillCloseAutomaticallyExitsFullscreen() {
        let window = makeFullscreenTestWindow()
        window.orderFrontRegardless()
        waitFullscreen { window.windowNumber > 0 }

        guard let style = NonNativeFullscreen(window) else {
            Issue.record("Expected NonNativeFullscreen to initialize")
            return
        }
        let originalFrame = window.frame
        style.enter()
        #expect(style.isFullscreen)
        waitFullscreen { window.frame != originalFrame }

        window.close()
        #expect(!style.isFullscreen)
    }

    /// Tako disallows native NSWindow tabbing and keeps its own tab groups;
    /// non-native fullscreen takes the window out of its group while
    /// fullscreen and must put it back on exit.
    @Test func exitRestoresTheWindowToItsTabGroup() async {
        let first = makeFullscreenTestWindow(at: 0)
        let second = makeFullscreenTestWindow(at: 450)
        defer {
            Tako.CustomTabGroup.leave(first)
            Tako.CustomTabGroup.leave(second)
            first.close()
            second.close()
        }
        first.orderFrontRegardless()
        waitFullscreen { first.windowNumber > 0 }
        Tako.CustomTabGroup.join(second, to: first, select: false)
        #expect(Tako.CustomTabGroup.group(for: first).windows.count == 2)

        guard let style = NonNativeFullscreen(first) else {
            Issue.record("Expected NonNativeFullscreen to initialize")
            return
        }
        let originalFrame = first.frame
        style.enter()
        #expect(style.isFullscreen)
        await waitAsync { first.frame != originalFrame }
        style.exit()

        let group = Tako.CustomTabGroup.group(for: first)
        #expect(group.windows.count == 2)
        #expect(group.windows.contains(second))
    }

    @Test func exitWithoutEverEnteringIsANoOp() {
        let window = makeFullscreenTestWindow()
        defer { window.close() }
        guard let style = NonNativeFullscreen(window) else {
            Issue.record("Expected NonNativeFullscreen to initialize")
            return
        }
        let frameBefore = window.frame
        style.exit()
        #expect(window.frame == frameBefore)
        #expect(!style.isFullscreen)
    }
}
