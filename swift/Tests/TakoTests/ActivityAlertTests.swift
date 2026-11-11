/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
import UserNotifications
@testable import Tako

/// Activity sounds (`activity-alert`, `activity-sound-<event>`): one decision
/// per status change, one sound at most. In front, Tako plays it with the
/// toast; in the background, macOS plays it with a notification; a program
/// that posts its own notification (OSC 7501) gets the chosen sound in it,
/// and no second one.
@Suite(.serialized) @MainActor
struct ActivityAlertTests {
    private func context(_ policy: ActivityAlertPolicy = .unfocused, sound: String? = "Glass", lookedAt: Bool = false,
                         muted: Bool = false, front: Bool = true, itself: Bool = false) -> ActivityAlert.Context {
        .init(policy: policy, sound: sound, lookedAt: lookedAt, muted: muted, takoInFront: front, reportsItself: itself)
    }

    @Test func oneDecisionPlaysOneSoundOneWay() {
        // Out of sight with Tako in front: the toast, and Tako plays the sound.
        #expect(ActivityAlert.decide(context()) == .init(toast: true, appSound: "Glass"))
        // Tako in the background or minimized: macOS shows it, with the sound.
        #expect(ActivityAlert.decide(context(front: false))
                == .init(toast: true, systemNotification: true, notificationSound: "Glass"))
        // Looking at the pane: nothing, unless «always», which only plays the sound.
        #expect(ActivityAlert.decide(context(lookedAt: true)) == .nothing)
        #expect(ActivityAlert.decide(context(.always, lookedAt: true)) == .init(appSound: "Glass"))
        // «never»: the toast as before, no sound, no notification.
        #expect(ActivityAlert.decide(context(.never, front: false)) == .init(toast: true))
        // Muted: nothing at all.
        #expect(ActivityAlert.decide(context(.always, muted: true)) == .nothing)
        // A program's own notification carries the sound: nothing more here.
        #expect(ActivityAlert.decide(context(front: false, itself: true)) == .init(toast: true))
        #expect(ActivityAlert.decide(context(itself: true)) == .init(toast: true))
        // «None» as the sound: still the notification, silent.
        #expect(ActivityAlert.decide(context(sound: nil, front: false))
                == .init(toast: true, systemNotification: true, notificationSound: nil))
    }

    @Test func aSettingNamesASystemSoundOrNone() {
        #expect(ActivitySounds.resolve("glass", for: .done) == "Glass")
        #expect(ActivitySounds.resolve(" Submarine ", for: .done) == "Submarine")
        #expect(ActivitySounds.resolve("none", for: .failed) == nil)
        #expect(ActivitySounds.resolve(nil, for: .needsYou) == "Glass", "the default for needs-you")
        #expect(ActivitySounds.resolve("doorbell", for: .failed) == "Basso", "an unknown name falls back to the event's sound")
        #expect(ActivitySounds.names.count == 14)
        for name in ActivitySounds.names {
            #expect(NSSound(named: NSSound.Name(name)) != nil, "\(name) is not a sound on this Mac")
        }

        let prefs = DesktopPreferences { key in
            ["activity-alert": "always", "activity-sound-done": "Pop", "activity-sound-failed": "none"][key]
        }
        #expect(prefs.activityAlert == .always)
        #expect(prefs.activitySound(.done) == "Pop")
        #expect(prefs.activitySound(.failed) == nil)
        #expect(prefs.activitySound(.needsYou) == "Glass")
        #expect(DesktopPreferences { _ in nil }.activityAlert == .unfocused)
    }

    @Test func aProgramsOwnNotificationGetsTheChosenSound() {
        let prefs = DesktopPreferences { ["activity-sound-failed": "none", "activity-sound-done": "Funk"][$0] }
        #expect(ActivitySoundChoice.forProgram(.done, preferences: prefs) == .named("Funk"))
        #expect(ActivitySoundChoice.forProgram(.failed, preferences: prefs) == .silent)
        #expect(ActivitySoundChoice.forProgram(nil, preferences: prefs) == .byUrgency)
        let never = DesktopPreferences { $0 == "activity-alert" ? "never" : nil }
        #expect(ActivitySoundChoice.forProgram(.done, preferences: never) == .byUrgency, "«never» leaves the program's own sound")

        let content = UNMutableNotificationContent()
        content.sound = .default
        ActivitySoundChoice.silent.apply(to: content)
        #expect(content.sound == nil)
    }

    /// The real path: a pane's status change in a loaded terminal window.
    @Test func aStatusChangeOutOfSightPlaysOrPostsOnce() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        let saved = (ActivityAlert.play, ActivityAlert.post, ActivityAlert.takoInFront, ActivityAlert.withdraw)
        defer { (ActivityAlert.play, ActivityAlert.post, ActivityAlert.takoInFront, ActivityAlert.withdraw) = saved }
        var played: [String] = [], posted: [UNNotificationRequest] = [], withdrawn: [String] = []
        var front = true
        ActivityAlert.play = { played.append($0) }
        ActivityAlert.post = { posted.append($0) }
        ActivityAlert.withdraw = { withdrawn.append($0) }
        ActivityAlert.takoInFront = { front }
        let center = PaneToastCenter()
        center.schedule = { _, _ in }

        center.statusChanged(surface, to: .needsApproval)
        #expect(played == ["Glass"] && posted.isEmpty, "in front: Tako plays it, once")

        front = false
        center.statusChanged(surface, to: .done)
        #expect(played == ["Glass"], "in the background Tako played a sound of its own too")
        let request = try #require(posted.first)
        #expect(posted.count == 1 && request.identifier == ActivityAlert.requestID(surface.id))
        #expect(request.content.sound != nil && request.content.title.hasSuffix("— done"))

        center.statusChanged(surface, to: .running)
        #expect(posted.count == 1 && played.count == 1, "running is no news")

        center.seen(surface.id)
        #expect(withdrawn == [ActivityAlert.requestID(surface.id)], "looking at the pane takes its notification back")
    }
}
