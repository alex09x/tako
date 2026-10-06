import Cocoa
import ApplicationServices
import CoreGraphics
import Carbon
import OSLog
import TakoKit

// Manages the event tap to monitor global events, currently only used for
// global keybindings.
class GlobalEventTap {
    static let shared = GlobalEventTap()

    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tako-core.terminal",
        category: String(describing: GlobalEventTap.self)
    )

    // The event tap used for global event listening. This is non-nil if it is
    // created.
    fileprivate var eventTap: CFMachPort?

    // Polls Accessibility permission before enabling the global event tap.
    private var enableTimer: Timer?

    // What the tap needs from macOS. Tests substitute it to drive the
    // permission-polling path, which a machine that has already granted
    // Accessibility never takes.
    struct System {
        var isTrusted: () -> Bool = { AXIsProcessTrusted() }
        var requestTrust: () -> Void = {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        var createTap: (CGEventMask) -> CFMachPort? = { eventMask in
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: cgEventFlagsChangedHandler(proxy:type:cgEvent:userInfo:),
                userInfo: nil
            )
        }
        var pollInterval: TimeInterval = 1
    }

    private let system: System

    // The app uses `shared`; other instances exist only in tests.
    init(system: System = System()) {
        self.system = system
    }

    deinit {
        disable()
    }

    // Enable the global event tap. This is safe to call if it is already enabled or
    // waiting for Accessibility permission.
    func enable() {
        // If we already have a tap or we're already checking on a timer, do nothing.
        guard eventTap == nil, enableTimer == nil else { return }

        // Creating a CGEventTap without Accessibility permission leaks a Mach port
        // inside CoreGraphics on each failed attempt. Request permission once and
        // poll the non-leaking trust check instead of retrying tap creation.
        if system.isTrusted() {
            _ = tryEnable()
            return
        }

        // Ask macOS to prompt for Accessibility access. Approval happens
        // asynchronously, so ignore the current result and poll below.
        Self.logger.info("No accessibility permission detected, prompting...")
        system.requestTrust()

        // Check in a timer
        enableTimer = Timer.scheduledTimer(withTimeInterval: system.pollInterval, repeats: true) { [weak self] _ in
            guard let self, self.system.isTrusted() else { return }

            // Stop polling before attempting creation. If creation fails for a
            // reason other than permissions, we must not retry it indefinitely.
            self.enableTimer?.invalidate()
            self.enableTimer = nil
            _ = self.tryEnable()
        }
    }

    // Disable the global event tap. This is safe to call if it is already disabled.
    func disable() {
        // Stop our enable timer if it is on
        if let enableTimer {
            enableTimer.invalidate()
            self.enableTimer = nil
        }

        // Stop our event tap
        if let eventTap {
            Self.logger.debug("invalidating event tap mach port")
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    // Try to enable the global event type, returns false if it fails.
    private func tryEnable() -> Bool {
        // The events we care about
        let eventMask = [
            CGEventType.keyDown
        ].reduce(CGEventMask(0), { $0 | (1 << $1.rawValue)})

        // Try to create it
        guard let eventTap = system.createTap(eventMask) else {
            Self.logger.warning("creating global event tap failed despite Accessibility permission")
            return false
        }

        // Store our event tap. Both callers have already stopped the
        // permission poll, so there is no timer left to cancel.
        self.eventTap = eventTap

        // Attach our event tap to the main run loop. A tap nobody services
        // holds up every event it intercepts until macOS disables it.
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            CFMachPortCreateRunLoopSource(nil, eventTap, 0),
            .commonModes
        )

        Self.logger.info("global event tap enabled for global keybinds")
        return true
    }
}

// Not `private`: the real callback is only ever invoked by CoreGraphics when
// a live global keyDown event passes through a trusted, installed event tap
// -- there's no way to synthesize that delivery path from a non-interactive
// `swift test` host. Its own logic takes no environment-only dependency
// beyond what's already visible through public state (`NSApp`, `GlobalEventTap.shared`),
// so `internal` visibility lets tests call it directly with constructed
// `CGEvent`s instead.
func cgEventFlagsChangedHandler(
    proxy: CGEventTapProxy,
    type: CGEventType,
    cgEvent: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let result = Unmanaged.passUnretained(cgEvent)

    // macOS disables the event tap if the callback is too slow or for other
    // internal reasons. When that happens it sends this event type. We need
    // to re-enable the tap or it stays dead forever.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        GlobalEventTap.logger.warning("global event tap was disabled by the system, re-enabling")
        if let machPort = GlobalEventTap.shared.eventTap {
            CGEvent.tapEnable(tap: machPort, enable: true)
        }
        return result
    }

    // We only care about keydown events
    guard type == .keyDown else { return result }

    // If our app is currently active then we don't process the key event.
    // This is because we already have a local event handler in AppDelegate
    // that processes all local events.
    guard !NSApp.isActive else { return result }

    // We need an app delegate to get the Tako app instance
    guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return result }
    guard let tako = appDelegate.tako.app else { return result }

    // We need an NSEvent for our logic below
    guard let event: NSEvent = .init(cgEvent: cgEvent) else { return result }

    // Build our event input and call tako
    let key_ev = event.takoKeyEvent(TAKO_ACTION_PRESS)
    if tako_app_key(tako, key_ev) {
        GlobalEventTap.logger.info("global key event handled event=\(event, privacy: .public)")
        return nil
    }

    return result
}
