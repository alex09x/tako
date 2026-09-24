import Testing
import AppKit
import ApplicationServices
@testable import Tako

/// `GlobalEventTap` keeps its Mach port / poll timer (`eventTap`,
/// `enableTimer`) `fileprivate` to GlobalEventTap.swift, and `enable()`
/// itself gates real tap installation behind a live macOS Accessibility
/// trust grant this test host cannot toggle. This suite exercises
/// `enable()`/`disable()` (its only two public entry points) and pins the
/// one cross-cutting invariant that matters for a background event tap:
/// installing (or trying to install) one must never wedge the main run
/// loop the rest of the app depends on. It also calls
/// `cgEventFlagsChangedHandler` directly (see its own doc comment) since
/// real delivery through an installed tap needs a live global keyDown
/// event no non-interactive host can synthesize.
@MainActor
struct GlobalEventTapTests {
    @Test func disableWithoutAPriorEnableDoesNotDisturbAccessibilityTrust() {
        let before = AXIsProcessTrusted()
        GlobalEventTap.shared.disable()
        #expect(AXIsProcessTrusted() == before)
    }

    /// A bare `swift test` host never drains GCD's main queue (see the
    /// documented caveat on
    /// `TakoAppAdapterCoverageTests.moveFocusWithADelayDoesNotCrash`), so a
    /// `DispatchQueue.main.async` probe would never fire here regardless of
    /// whether the run loop is wedged. `Timer`, by contrast, is driven
    /// directly by the `CFRunLoop` that `QTTestSupport.waitUntil` pumps, so
    /// it is the correct probe for "did installing/tearing down the tap
    /// leave the main run loop able to keep running timers".
    private static func mainRunLoopStillProcessesTimers() -> Bool {
        var fired = false
        let probe = Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { _ in fired = true }
        defer { probe.invalidate() }
        QTTestSupport.waitUntil(timeout: 1) { fired }
        return fired
    }

    @Test func repeatedEnableCallsAreIdempotentAndRepeatedDisableCallsAreSafe() {
        GlobalEventTap.shared.enable()
        GlobalEventTap.shared.enable()
        GlobalEventTap.shared.disable()
        GlobalEventTap.shared.disable()

        #expect(Self.mainRunLoopStillProcessesTimers())
    }

    @Test func enablingDoesNotWedgeTheMainRunLoop() {
        GlobalEventTap.shared.enable()
        defer { GlobalEventTap.shared.disable() }

        // Whichever branch `enable()` takes internally -- installing a real
        // CGEvent tap (and its CFRunLoopAddSource) when this host's process
        // is Accessibility-trusted, or scheduling the polling prompt timer
        // otherwise -- the main run loop must keep processing other timers.
        #expect(Self.mainRunLoopStillProcessesTimers())
    }

    @Test func enableTwiceThenDisableTwiceLeavesTheTapReadyToEnableAgain() {
        GlobalEventTap.shared.enable()
        GlobalEventTap.shared.disable()

        // A second full cycle must behave the same as the first: this is
        // only observable indirectly (no crash / hang), since eventTap and
        // enableTimer are both fileprivate to GlobalEventTap.swift.
        GlobalEventTap.shared.enable()
        defer { GlobalEventTap.shared.disable() }

        #expect(Self.mainRunLoopStillProcessesTimers())
    }

    // MARK: - cgEventFlagsChangedHandler

    /// The real tap callback is only ever invoked by CoreGraphics when a
    /// live global keyDown event passes through an actually-installed,
    /// trusted event tap -- not something a non-interactive `swift test`
    /// host can synthesize delivery for. `cgEventFlagsChangedHandler` is
    /// `internal` (see its doc comment in GlobalEventTap.swift) precisely so
    /// these tests can call it directly with constructed `CGEvent`s instead,
    /// which exercises its actual decision logic deterministically.
    private func dummyProxy() -> CGEventTapProxy {
        OpaquePointer(bitPattern: 1)!
    }

    private func keyDownEvent(keyCode: CGKeyCode = 0) throws -> CGEvent {
        try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
    }

    @Test func handlerReEnablesTheRealTapWhenDisabledByTimeoutOrUserInput() throws {
        GlobalEventTap.shared.enable()
        defer { GlobalEventTap.shared.disable() }
        let event = try keyDownEvent()

        let timeoutResult = cgEventFlagsChangedHandler(
            proxy: dummyProxy(), type: .tapDisabledByTimeout, cgEvent: event, userInfo: nil)
        #expect(timeoutResult?.takeUnretainedValue() === event)

        let userInputResult = cgEventFlagsChangedHandler(
            proxy: dummyProxy(), type: .tapDisabledByUserInput, cgEvent: event, userInfo: nil)
        #expect(userInputResult?.takeUnretainedValue() === event)
    }

    @Test func handlerIgnoresEventTypesOtherThanKeyDown() throws {
        let event = try keyDownEvent()
        let result = cgEventFlagsChangedHandler(
            proxy: dummyProxy(), type: .flagsChanged, cgEvent: event, userInfo: nil)
        #expect(result?.takeUnretainedValue() === event)
    }

    @Test func handlerForwardsTheEventUnchangedWhenNoAppDelegateIsInstalled() throws {
        _ = NSApplication.shared
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        defer { NSApplication.shared.delegate = originalDelegate }
        let event = try keyDownEvent()

        // `NSApp.isActive` is false for this test host (confirmed: this
        // process cannot win real macOS activation in this harness), so the
        // `guard !NSApp.isActive` above the app-delegate lookup always lets
        // execution reach it here.
        let result = cgEventFlagsChangedHandler(
            proxy: dummyProxy(), type: .keyDown, cgEvent: event, userInfo: nil)
        #expect(result?.takeUnretainedValue() === event)
    }

    @Test func handlerForwardsAnUnboundKeyEventUnchangedWhenAnAppDelegateIsInstalled() throws {
        _ = NSApplication.shared
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }
        let event = try keyDownEvent()

        // A fresh `AppDelegate()`/`Tako.App()` has no configured global
        // keybinds, so `tako_app_key` reports the key unhandled and the
        // callback forwards the original event instead of swallowing it.
        let result = cgEventFlagsChangedHandler(
            proxy: dummyProxy(), type: .keyDown, cgEvent: event, userInfo: nil)
        #expect(result?.takeUnretainedValue() === event)
    }
}

/// The Accessibility-permission path, over a substitute `System`. A machine
/// that already trusts the test host (the test Mac does) never prompts or
/// polls, so without this the path users hit on first launch goes untested.
@MainActor
struct GlobalEventTapPermissionTests {
    private final class FakeSystem {
        var trusted = false
        var trustRequests = 0
        var tapAttempts = 0
        var createsTap = true

        var system: GlobalEventTap.System {
            GlobalEventTap.System(
                isTrusted: { self.trusted },
                requestTrust: { self.trustRequests += 1 },
                createTap: { _ in
                    self.tapAttempts += 1
                    // Any port stands in for the tap: the code under test
                    // only stores it, services it and invalidates it.
                    return self.createsTap ? CFMachPortCreate(nil, { _, _, _, _ in }, nil, nil) : nil
                },
                pollInterval: 0.01)
        }
    }

    /// Lets the 10 ms poll fire several times.
    private static func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    @Test func anUntrustedEnablePromptsOnceThenInstallsTheTapWhenTrustArrives() {
        let fake = FakeSystem()
        let tap = GlobalEventTap(system: fake.system)
        defer { tap.disable() }

        tap.enable()
        tap.enable()
        Self.pump()
        #expect(fake.trustRequests == 1)
        #expect(fake.tapAttempts == 0)

        fake.trusted = true
        #expect(QTTestSupport.waitUntil(timeout: 2) { fake.tapAttempts == 1 })

        // Installed: the poll is gone and enable() leaves the tap alone.
        Self.pump()
        tap.enable()
        #expect(fake.tapAttempts == 1)

        // disable() really drops it, so the next enable() installs anew.
        tap.disable()
        tap.enable()
        #expect(fake.tapAttempts == 2)
    }

    @Test func aTapThatCannotBeCreatedDespiteTrustIsNotRetriedForever() {
        let fake = FakeSystem()
        fake.createsTap = false
        let tap = GlobalEventTap(system: fake.system)
        defer { tap.disable() }

        tap.enable()
        fake.trusted = true
        #expect(QTTestSupport.waitUntil(timeout: 2) { fake.tapAttempts == 1 })

        Self.pump()
        #expect(fake.tapAttempts == 1)
    }

    @Test func disablingWhileWaitingForTrustStopsThePoll() {
        let fake = FakeSystem()
        let tap = GlobalEventTap(system: fake.system)

        tap.enable()
        tap.disable()
        fake.trusted = true
        Self.pump()

        #expect(fake.tapAttempts == 0)
    }

    /// The poll holds its tap weakly, so a tap still waiting for trust can
    /// be released -- and releasing it tears the poll down.
    @Test func aTapWaitingForTrustIsNotKeptAliveByItsPoll() {
        let fake = FakeSystem()
        weak var released: GlobalEventTap?
        do {
            let tap = GlobalEventTap(system: fake.system)
            tap.enable()
            released = tap
        }

        fake.trusted = true
        Self.pump()

        #expect(released == nil)
        #expect(fake.tapAttempts == 0)
    }
}
