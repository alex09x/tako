import Testing
import AppKit
@testable import Tako

/// `SecureInput` is a process-wide singleton wrapping the real Carbon
/// `EnableSecureEventInput`/`DisableSecureEventInput` calls, which are gated
/// on `NSApp.isActive`. Every test restores `global`/scoped state afterward
/// so later tests (and this shared test Mac) see the singleton back at its
/// resting state.
@MainActor
struct SecureInputTests {
    /// Best-effort activation, mirroring the same caveat documented on
    /// `TakoAppAdapterCoverageTests.focusedWorkingDirectoryReadsTheKeyWindowsFirstResponderSurface`:
    /// whether a non-interactive test host grants this process activation is
    /// environment-dependent.
    private static func tryActivate() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        QTTestSupport.waitUntil(timeout: 1) { NSApplication.shared.isActive }
        return NSApplication.shared.isActive
    }

    /// `onDidBecomeActive`/`onDidResignActive` -- unlike `apply()` -- never
    /// gate on `NSApp.isActive` themselves; they only check `SecureInput`'s
    /// own `enabled`/`desired` state. Posting these notifications directly
    /// therefore reaches the real `EnableSecureEventInput()`/
    /// `DisableSecureEventInput()` calls (and their success-logging paths)
    /// even on a host where this process can never win real macOS
    /// activation (confirmed: `tryActivate()` returns `false` here, unlike
    /// `apply()`'s own success path, which stays unreachable without it).
    @Test func becomingActiveEnablesAndResigningDisablesRegardlessOfHostActivation() {
        _ = NSApplication.shared
        let originalGlobal = SecureInput.shared.global
        SecureInput.shared.global = true
        defer { SecureInput.shared.global = originalGlobal }

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(SecureInput.shared.enabled)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!SecureInput.shared.enabled)
    }

    @Test func globalDefaultsToFalseAndEnabledDefaultsToFalse() {
        #expect(!SecureInput.shared.global)
        #expect(!SecureInput.shared.enabled)
    }

    @Test func settingGlobalTrueEnablesSecureInputOnlyWhenAppIsActive() {
        let active = Self.tryActivate()
        defer { SecureInput.shared.global = false }

        SecureInput.shared.global = true

        if active {
            #expect(SecureInput.shared.enabled)
        } else {
            // `apply()`'s `guard NSApp.isActive else { return }` is what ran
            // instead: `enabled` cannot leave its resting `false`.
            #expect(!SecureInput.shared.enabled)
        }
    }

    @Test func settingGlobalBackToFalseDisablesSecureInput() {
        let active = Self.tryActivate()
        SecureInput.shared.global = true
        defer { SecureInput.shared.global = false }

        SecureInput.shared.global = false

        #expect(!SecureInput.shared.enabled)
        _ = active
    }

    @Test func scopedFocusEnablesSecureInputWhileFocusedAndDisablesWhenUnfocused() {
        let active = Self.tryActivate()
        let object = ObjectIdentifier(NSObject())
        defer { SecureInput.shared.removeScoped(object) }

        SecureInput.shared.setScoped(object, focused: true)
        if active {
            #expect(SecureInput.shared.enabled)
        }

        SecureInput.shared.setScoped(object, focused: false)
        if active {
            #expect(!SecureInput.shared.enabled)
        }
    }

    @Test func removingAScopedObjectDropsItsContributionToTheDesiredState() {
        let active = Self.tryActivate()
        let object = ObjectIdentifier(NSObject())
        SecureInput.shared.setScoped(object, focused: true)

        SecureInput.shared.removeScoped(object)

        if active {
            #expect(!SecureInput.shared.enabled)
        }
    }

    @Test func multipleScopedObjectsKeepSecureInputEnabledUntilAllAreUnfocused() {
        let active = Self.tryActivate()
        let a = ObjectIdentifier(NSObject())
        let b = ObjectIdentifier(NSObject())
        defer {
            SecureInput.shared.removeScoped(a)
            SecureInput.shared.removeScoped(b)
        }

        SecureInput.shared.setScoped(a, focused: true)
        SecureInput.shared.setScoped(b, focused: true)
        SecureInput.shared.setScoped(a, focused: false)
        if active {
            // b is still focused, so secure input must remain enabled.
            #expect(SecureInput.shared.enabled)
        }

        SecureInput.shared.setScoped(b, focused: false)
        if active {
            #expect(!SecureInput.shared.enabled)
        }
    }

    @Test func resignAndBecomeActiveNotificationsToggleEnabledWhenGloballyDesired() {
        guard Self.tryActivate() else {
            // Without activation this test process can't be told it resigned
            // active, so there is nothing to toggle away from.
            #expect(!SecureInput.shared.enabled)
            return
        }
        SecureInput.shared.global = true
        defer { SecureInput.shared.global = false }
        #expect(SecureInput.shared.enabled)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!SecureInput.shared.enabled)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(SecureInput.shared.enabled)
    }
}

/// `SecureInput`'s state machine over a substitute `System`: the host
/// process is never the active app (so the real `apply()` stops at its
/// first guard), and the real Carbon calls never fail on demand. Each test
/// owns its instance, so nothing here touches the process-wide secure input
/// state or `SecureInput.shared`.
@MainActor
struct SecureInputStateMachineTests {
    private final class FakeSystem {
        var active = true
        var status: OSStatus = noErr
        var enables = 0
        var disables = 0

        var system: SecureInput.System {
            SecureInput.System(
                isActive: { self.active },
                enable: { self.enables += 1; return self.status },
                disable: { self.disables += 1; return self.status })
        }
    }

    @Test func turningGlobalOnAndOffWhileActiveEnablesThenDisablesOnce() {
        let fake = FakeSystem()
        let input = SecureInput(system: fake.system)

        input.global = true
        #expect(input.enabled)
        #expect(fake.enables == 1)

        // Already in the desired state: no second Carbon call.
        input.global = true
        #expect(fake.enables == 1)

        input.global = false
        #expect(!input.enabled)
        #expect(fake.disables == 1)
    }

    @Test func aFocusedScopedObjectEnablesUntilItLosesFocusOrIsRemoved() {
        let fake = FakeSystem()
        let input = SecureInput(system: fake.system)
        let field = ObjectIdentifier(NSObject())

        input.setScoped(field, focused: false)
        #expect(!input.enabled)
        #expect(fake.enables == 0)

        input.setScoped(field, focused: true)
        #expect(input.enabled)

        input.removeScoped(field)
        #expect(!input.enabled)
        #expect(fake.disables == 1)
    }

    @Test func nothingHappensWhileTheAppIsInactive() {
        let fake = FakeSystem()
        fake.active = false
        let input = SecureInput(system: fake.system)

        input.global = true

        #expect(!input.enabled)
        #expect(fake.enables == 0)
    }

    @Test func aFailedEnableLeavesSecureInputOffAndIsRetriedOnTheNextChange() {
        let fake = FakeSystem()
        fake.status = OSStatus(paramErr)
        let input = SecureInput(system: fake.system)

        input.global = true
        #expect(!input.enabled)
        #expect(fake.enables == 1)

        fake.status = noErr
        input.setScoped(ObjectIdentifier(input), focused: true)
        #expect(input.enabled)
        #expect(fake.enables == 2)
    }

    @Test func aFailedDisableKeepsReportingSecureInputAsOn() {
        let fake = FakeSystem()
        let input = SecureInput(system: fake.system)
        input.global = true

        fake.status = OSStatus(paramErr)
        input.global = false

        // The system still has it on, so `enabled` must keep saying so.
        #expect(input.enabled)
        #expect(fake.disables == 1)
    }

    @Test func activationNotificationsYieldAndReacquireSecureInput() {
        let fake = FakeSystem()
        let input = SecureInput(system: fake.system)
        input.global = true

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!input.enabled)
        #expect(fake.disables == 1)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(input.enabled)
        #expect(fake.enables == 2)
    }

    @Test func activationNotificationsWhoseCarbonCallFailsLeaveTheStateAlone() {
        let fake = FakeSystem()
        let input = SecureInput(system: fake.system)
        input.global = true

        fake.status = OSStatus(paramErr)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(input.enabled)

        fake.status = noErr
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(!input.enabled)

        fake.status = OSStatus(paramErr)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(!input.enabled)
    }

    @Test func releasingAnEnabledInstanceBalancesItsEnableWithADisable() {
        let fake = FakeSystem()
        weak var released: SecureInput?
        do {
            let input = SecureInput(system: fake.system)
            input.global = true
            released = input
        }

        #expect(released == nil)
        #expect(fake.enables == 1)
        #expect(fake.disables == 1)
    }
}
