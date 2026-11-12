/*
 * tako — Activity sounds and notifications for what happens out of sight
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import UserNotifications

/// What happened in a pane that is worth a sound: it needs you, it is done,
/// it failed. Each has its own sound (`activity-sound-<event>`).
enum ActivityEvent: String, CaseIterable, Sendable {
    case needsYou = "needs-you", done, failed

    var soundKey: String { "activity-sound-\(rawValue)" }
    var defaultSound: String {
        switch self {
        case .needsYou: "Glass"
        case .done: "Hero"
        case .failed: "Basso"
        }
    }

    init?(_ status: Tako.PaneStatus) {
        switch status {
        case .needsApproval, .waitingForInput: self = .needsYou
        case .done: self = .done
        case .error: self = .failed
        default: return nil
        }
    }
}

/// When a pane's news makes a sound (`activity-alert`): only while you are
/// not looking at that pane, also when you are, or never.
enum ActivityAlertPolicy: String, CaseIterable, Sendable {
    case unfocused, always, never
}

/// The macOS system sounds, by name, or none.
enum ActivitySounds {
    static let none = "none"
    static let names = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    static var choices: [String] { [none] + names }

    /// The sound a setting names; nil for none. A name Tako does not know
    /// falls back to the event's own sound.
    static func resolve(_ raw: String?, for event: ActivityEvent) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return event.defaultSound }
        if raw.lowercased() == none { return nil }
        return names.first { $0.lowercased() == raw.lowercased() } ?? event.defaultSound
    }

    /// The chosen sound inside a system notification: copied into Tako's
    /// sound cache (ActivitySoundCache), where UNNotificationSound(named:)
    /// looks. A build that cannot use the cache (not signed by Tako's team,
    /// no group entitlement) falls back to macOS's notification sound, and
    /// says so in the log once per reason.
    @MainActor static func notificationSound(_ name: String) -> UNNotificationSound {
        if let file = placed[name] { return UNNotificationSound(named: UNNotificationSoundName(rawValue: file)) }
        switch place(name, names) {
        case .success(let result):
            placed[name] = result.fileName
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: result.fileName))
        case .failure(let why):
            if reported.insert("\(why)").inserted {
                NSLog("tako: activity sound %@ not available to notifications (%@); macOS's notification sound plays", name, "\(why)")
            }
            return .default
        }
    }

    /// Tests replace this; the app places sounds through its signed group.
    @MainActor static var place: (String, [String]) -> Result<ActivitySoundCache.Placed, ActivitySoundCache.Failure> = {
        ActivitySoundCache.place($0, known: $1)
    }
    @MainActor private static var placed: [String: String] = [:]
    @MainActor private static var reported: Set<String> = []
    @MainActor static func forgetPlacedForTesting() { placed = [:]; reported = [] }
}

/// The sound of a notification a program posts itself (OSC 7501). Explicit
/// notification requests (OSC 9/777/99) keep their urgency's sound; Tako's
/// own status alerts follow the activity sound settings.
public enum ActivitySoundChoice: Equatable {
    case byUrgency
    case sound(String)
    case silent

    @MainActor public func apply(to content: UNMutableNotificationContent) {
        switch self {
        case .byUrgency: break
        case .sound(let name): content.sound = ActivitySounds.notificationSound(name)
        case .silent: content.sound = nil
        }
    }

    /// For a program's own blocked / done / error report: silent under
    /// «Never» or a sound set to None, else the event's chosen sound.
    static func forProgram(_ event: ActivityEvent?, preferences: DesktopPreferences) -> ActivitySoundChoice {
        guard let event else { return .byUrgency }
        guard preferences.activityAlert != .never, let name = preferences.activitySound(event) else { return .silent }
        return .sound(name)
    }

    /// The route for a program's own report, decided when it happens and
    /// written into its notification. With a terminal window of Tako in front,
    /// Tako plays the sound itself (as for any other news) and the notification
    /// goes out silent, so it does not depend on macOS notifications being
    /// allowed and never adds a second sound when presented later. In the
    /// background the notification carries the sound, as before.
    @MainActor static func forProgramNow(_ event: ActivityEvent?, lookedAt: Bool, muted: Bool,
                                         preferences: DesktopPreferences) -> ActivitySoundChoice {
        guard let event else { return .byUrgency }
        guard ActivityAlert.takoInFront() else { return forProgram(event, preferences: preferences) }
        let decision = ActivityAlert.decide(.init(policy: preferences.activityAlert, sound: preferences.activitySound(event),
                                                  lookedAt: lookedAt, muted: muted, takoInFront: true, reportsItself: false))
        if let sound = decision.appSound { ActivityAlert.play(sound) }
        return .silent
    }
}

/// Where activity notifications go: the system's notification center in the
/// app, a recorder in tests.
@MainActor protocol ActivityNotificationTransport {
    func add(_ request: UNNotificationRequest)
    func removePending(_ ids: [String])
    func removeDelivered(_ ids: [String])
}

@MainActor private struct SystemNotificationTransport: ActivityNotificationTransport {
    let center: UNUserNotificationCenter
    func add(_ request: UNNotificationRequest) {
        center.add(request) { error in
            // Scheduling failed; a nil error says nothing about presentation.
            if let error { NSLog("tako: activity notification not scheduled: %@", error.localizedDescription) }
        }
    }
    func removePending(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
}

/// One decision per status change: a toast, a sound Tako plays itself, or a
/// system notification (with or without its sound). Never both sounds: while
/// a terminal window of Tako is in front, Tako plays it; otherwise macOS
/// does, with the notification, so Focus and the notification settings apply.
/// «Play sounds» governs sound only: with Never, a pane out of sight still
/// gets its toast and, in the background, a silent notification.
struct ActivityAlertDecision: Equatable {
    var toast = false
    var appSound: String?
    var systemNotification = false
    var notificationSound: String?

    static let nothing = ActivityAlertDecision()
}

enum ActivityAlert {
    struct Context {
        var policy: ActivityAlertPolicy
        var sound: String?
        var lookedAt: Bool
        var muted: Bool
        /// Tako is active with a terminal window in front, where toasts show.
        var takoInFront: Bool
        /// The program reports this status itself (OSC 7501) and posts its own
        /// notification, which already follows these settings.
        var reportsItself: Bool
        /// `notify-on-command-finish` already rang or posted for this end.
        var alreadySignalled = false
    }

    static func decide(_ c: Context) -> ActivityAlertDecision {
        guard !c.muted else { return .nothing }
        let sound = c.policy == .never ? nil : c.sound
        if c.lookedAt {
            // A pane in view gets no toast; «always» still plays its sound.
            guard c.policy == .always, !c.alreadySignalled else { return .nothing }
            return ActivityAlertDecision(appSound: sound)
        }
        var decision = ActivityAlertDecision(toast: true)
        guard !c.reportsItself, !c.alreadySignalled else { return decision }
        if c.takoInFront {
            decision.appSound = sound
        } else {
            decision.systemNotification = true
            decision.notificationSound = sound
        }
        return decision
    }

    /// Whether Tako is active with one of its terminal windows in front.
    @MainActor static var takoInFront: () -> Bool = {
        guard NSApp.isActive, let window = NSApp.keyWindow, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible) else { return false }
        return window.windowController is BaseTerminalController
    }

    /// A test process plays and posts nothing unless a test sets these.
    static let inTests = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Tests replace these; the app plays and posts for real.
    @MainActor static var play: (String) -> Void = { name in
        guard !inTests else { return }
        NSSound(named: NSSound.Name(name))?.play() }
    /// The notification center; none in a test process unless a test sets one.
    @MainActor static var transport: () -> ActivityNotificationTransport? = {
        guard !inTests, let center = AppDelegate.notificationCenterProvider() else { return nil }
        return SystemNotificationTransport(center: center)
    }

    @MainActor static func post(_ request: UNNotificationRequest) {
        transport()?.add(request)
        Tako.onNotificationPosted?(request)
    }

    /// A pane you look at takes its notification back: delivered, and also
    /// still pending (adding is asynchronous), and only that pane's.
    @MainActor static func withdraw(_ id: String) {
        guard let transport = transport() else { return }
        transport.removePending([id])
        transport.removeDelivered([id])
    }

    /// One identifier per pane: a newer state replaces the older one.
    static func requestID(_ surface: UUID) -> String { "tako-activity-\(surface.uuidString)" }
}
