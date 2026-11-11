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

    /// The same sound inside a system notification.
    static func notificationSound(_ name: String) -> UNNotificationSound {
        UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(name).aiff"))
    }
}

/// The sound of a notification a program posts itself (OSC 7501): its
/// urgency's, as before, or the activity sound chosen for its event.
public enum ActivitySoundChoice: Equatable {
    case byUrgency
    case named(String)
    case silent

    public func apply(to content: UNMutableNotificationContent) {
        switch self {
        case .byUrgency: break
        case .named(let name): content.sound = ActivitySounds.notificationSound(name)
        case .silent: content.sound = nil
        }
    }

    /// For a program's own blocked / done / error report, under the settings.
    static func forProgram(_ event: ActivityEvent?, preferences: DesktopPreferences) -> ActivitySoundChoice {
        guard let event, preferences.activityAlert != .never else { return .byUrgency }
        return preferences.activitySound(event).map(ActivitySoundChoice.named) ?? .silent
    }
}

/// One decision per status change: a toast, a sound Tako plays itself, or a
/// system notification carrying the sound. Never both sounds: while a
/// terminal window of Tako is in front, Tako plays it; otherwise macOS does,
/// with the notification, so Focus and the notification settings apply.
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
        /// notification, which already carries the sound.
        var reportsItself: Bool
    }

    static func decide(_ c: Context) -> ActivityAlertDecision {
        guard !c.muted else { return .nothing }
        let sounds = c.policy != .never
        if c.lookedAt {
            // A pane in view gets no toast; «always» still plays its sound.
            return c.policy == .always ? ActivityAlertDecision(appSound: c.sound) : .nothing
        }
        var decision = ActivityAlertDecision(toast: true)
        guard sounds, !c.reportsItself else { return decision }
        if c.takoInFront {
            decision.appSound = c.sound
        } else {
            decision.systemNotification = true
            decision.notificationSound = c.sound
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
    @MainActor static var post: (UNNotificationRequest) -> Void = { request in
        guard !inTests else { return }
        AppDelegate.notificationCenterProvider()?.add(request) { error in
            // Scheduling failed; a nil error says nothing about presentation.
            if let error { NSLog("tako: activity notification not scheduled: %@", error.localizedDescription) }
        }
        Tako.onNotificationPosted?(request)
    }

    /// A pane you look at takes its notification back from Notification Center.
    @MainActor static var withdraw: (String) -> Void = { id in
        guard !inTests else { return }
        AppDelegate.notificationCenterProvider()?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// One identifier per pane: a newer state replaces the older one.
    static func requestID(_ surface: UUID) -> String { "tako-activity-\(surface.uuidString)" }
}
