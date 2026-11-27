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
import TakoCoreUI
import Testing
import UserNotifications
@testable import Tako

/// Activity sounds (`activity-alert`, `activity-sound-<event>`): one decision
/// per status change, one sound at most. In front, Tako plays the chosen
/// sound with the toast; in the background, macOS shows a notification with
/// its notification sound; «Never» silences both and keeps the notification;
/// a program's own status notification (OSC 7501) follows the same settings;
/// notify-on-command-finish keeps its own signal and gets no second one.
@Suite(.serialized) @MainActor
struct ActivityAlertTests {
    private final class Transport: ActivityNotificationTransport {
        var added: [UNNotificationRequest] = [], pending: [[String]] = [], delivered: [[String]] = []
        func add(_ request: UNNotificationRequest) { added.append(request) }
        func removePending(_ ids: [String]) { pending.append(ids) }
        func removeDelivered(_ ids: [String]) { delivered.append(ids) }
    }

    private func context(_ policy: ActivityAlertPolicy = .unfocused, sound: String? = "Glass", lookedAt: Bool = false,
                         muted: Bool = false, front: Bool = true, itself: Bool = false,
                         signalled: Bool = false) -> ActivityAlert.Context {
        .init(policy: policy, sound: sound, lookedAt: lookedAt, muted: muted, takoInFront: front,
              reportsItself: itself, alreadySignalled: signalled)
    }

    private func with(_ prefs: [String: String], _ body: () throws -> Void) rethrows {
        let saved = DesktopPresentation.shared.preferences
        DesktopPresentation.shared.apply(DesktopPreferences { prefs[$0] })
        defer { DesktopPresentation.shared.apply(saved) }
        try body()
    }

    @Test func oneDecisionPlaysOneSoundOneWay() {
        #expect(ActivityAlert.decide(context()) == .init(toast: true, appSound: "Glass"), "in front: Tako plays it")
        #expect(ActivityAlert.decide(context(front: false)) == .init(toast: true, systemNotification: true, notificationSound: "Glass"))
        #expect(ActivityAlert.decide(context(lookedAt: true)) == .nothing)
        #expect(ActivityAlert.decide(context(.always, lookedAt: true)) == .init(appSound: "Glass"))
        // «Never» is about sound: the toast and a silent background notification stay.
        #expect(ActivityAlert.decide(context(.never)) == .init(toast: true))
        #expect(ActivityAlert.decide(context(.never, front: false)) == .init(toast: true, systemNotification: true))
        #expect(ActivityAlert.decide(context(.never, lookedAt: true)) == .nothing)
        #expect(ActivityAlert.decide(context(.always, muted: true)) == .nothing)
        // A program's own notification, or notify-on-command-finish, already said it.
        #expect(ActivityAlert.decide(context(front: false, itself: true)) == .init(toast: true))
        #expect(ActivityAlert.decide(context(front: false, signalled: true)) == .init(toast: true))
        #expect(ActivityAlert.decide(context(.always, lookedAt: true, signalled: true)) == .nothing)
        // «None» as the sound: the notification, silent.
        #expect(ActivityAlert.decide(context(sound: nil, front: false)) == .init(toast: true, systemNotification: true))
    }

    @Test func aSettingNamesASystemSoundOrNone() {
        #expect(ActivitySounds.resolve("glass", for: .done) == "Glass")
        #expect(ActivitySounds.resolve(" Submarine ", for: .done) == "Submarine")
        #expect(ActivitySounds.resolve("none", for: .failed) == nil)
        #expect(ActivitySounds.resolve(nil, for: .needsYou) == "Glass")
        #expect(ActivitySounds.resolve("doorbell", for: .failed) == "Basso", "an unknown name falls back to the event's sound")
        for name in ActivitySounds.names {
            #expect(NSSound(named: NSSound.Name(name)) != nil, "\(name) is not a sound Tako can play in front")
        }
        let prefs = DesktopPreferences { ["activity-alert": "always", "activity-sound-done": "Pop", "activity-sound-failed": "none"][$0] }
        #expect(prefs.activityAlert == .always && prefs.activitySound(.done) == "Pop")
        #expect(prefs.activitySound(.failed) == nil && prefs.activitySound(.needsYou) == "Glass")
        #expect(DesktopPreferences { _ in nil }.activityAlert == .unfocused)
    }

    /// A notification carries the chosen sound from Tako's sound cache; a
    /// build that cannot reach the cache plays macOS's notification sound.
    @Test func aNotificationCarriesTheCachedSoundOrMacOSsOwn() {
        let saved = ActivitySounds.place
        defer { ActivitySounds.place = saved; ActivitySounds.forgetPlacedForTesting() }
        ActivitySounds.forgetPlacedForTesting()
        // This test process is not signed into Tako's group: the real cache refuses it.
        if case .failure(let why) = ActivitySoundCache.place("Glass", known: ActivitySounds.names) {
            #expect(why == .notEntitled)
        } else { Issue.record("an unentitled process placed a sound") }
        #expect(ActivitySounds.notificationSound("Glass") == .default)

        ActivitySounds.forgetPlacedForTesting()
        var asked: [String] = []
        ActivitySounds.place = { name, _ in
            asked.append(name)
            return .success(.init(fileName: "tako-\(name).aiff", url: URL(fileURLWithPath: "/x"), sha256: ""))
        }
        let sound = ActivitySounds.notificationSound("Glass")
        #expect(sound == UNNotificationSound(named: UNNotificationSoundName(rawValue: "tako-Glass.aiff")))
        _ = ActivitySounds.notificationSound("Glass")
        #expect(asked == ["Glass"], "placed once, then remembered")
    }

    /// A program reports its own status (OSC 7501): the request it makes follows «Play sounds» and None.
    @Test func aProgramsOwnStatusNotificationFollowsTheSoundSettings() throws {
        TakoTerminalNSView.isMetalDisabledForTesting = true
        var config = Tako.SurfaceConfiguration()
        config.allowsSessionPersistence = false
        config.program = ["/usr/bin/true"]
        let saved = Tako.onNotificationPosted
        defer { Tako.onNotificationPosted = saved }
        var posted: [UNNotificationRequest] = []
        Tako.onNotificationPosted = { posted.append($0) }

        func report(_ state: String, id: String) -> UNNotificationRequest? {
            let surface = Tako.SurfaceView(nil, baseConfig: config, uuid: UUID(), theme: nil)
            surface.onExit = nil; surface.pty?.terminate(); surface.pty = nil; surface.resetTerminal()
            defer { surface.close() }
            surface.crab.isFocused = false
            NotificationCoalescer.shared.reset()
            posted = []
            let msg = Data("finished".utf8).base64EncodedString()
            surface.feed(data: Data("\u{1b}]7501;state=\(state):id=\(id):kind=task:app=Agent:msg=\(msg)\u{1b}\\".utf8))
            return posted.first { $0.identifier.contains("osc7501") }
        }

        try with([:]) {
            let request = try #require(report("done", id: "a"))
            #expect(request.content.sound != nil, "a program's done report lost its sound")
        }
        try with(["activity-alert": "never"]) {
            let request = try #require(report("done", id: "b"))
            #expect(request.content.sound == nil, "«Never» left a program's status notification sounding")
            let blocked = try #require(report("blocked", id: "c"))
            #expect(blocked.content.sound == nil)
        }
        try with(["activity-sound-failed": "none"]) {
            let request = try #require(report("error", id: "d"))
            #expect(request.content.sound == nil, "None left a failure sounding")
        }
    }

    /// The real path: a pane's status change in a loaded terminal window, through the transport.
    @Test func aStatusChangeOutOfSightPlaysOrPostsOnceAndLookingTakesItBack() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        let saved = (ActivityAlert.play, ActivityAlert.transport, ActivityAlert.takoInFront)
        defer { (ActivityAlert.play, ActivityAlert.transport, ActivityAlert.takoInFront) = saved }
        var played: [String] = []
        var front = true
        let transport = Transport()
        ActivityAlert.play = { played.append($0) }
        ActivityAlert.transport = { transport }
        ActivityAlert.takoInFront = { front }
        let center = PaneToastCenter()
        center.schedule = { _, _ in }

        center.statusChanged(surface, to: .needsApproval)
        #expect(played == ["Glass"] && transport.added.isEmpty, "in front: Tako plays it, once")

        front = false
        center.statusChanged(surface, to: .done)
        #expect(played == ["Glass"], "in the background Tako played a sound of its own too")
        let id = ActivityAlert.requestID(surface.id)
        let request = try #require(transport.added.first)
        #expect(transport.added.count == 1 && request.identifier == id && request.content.sound != nil)

        // Looked at before macOS delivered it: the pending request goes too, and nothing else.
        center.seen(surface.id)
        #expect(transport.pending == [[id]] && transport.delivered == [[id]])
    }

    /// notify-on-command-finish rang or posted for a long command: the same end gets no second signal.
    @Test func aCommandFinishSignalIsNotDoubled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tako")
        try "notify-on-command-finish = always\nnotify-on-command-finish-after = 2s\nnotify-on-command-finish-action = no-bell\n"
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = Tako.App(configPath: url.path)   // the surface holds its app weakly
        let surface = Tako.SurfaceView(app, baseConfig: nil)
        defer { surface.close(); withExtendedLifetime(app) {} }
        let saved = (ActivityAlert.play, ActivityAlert.transport, ActivityAlert.takoInFront)
        defer { (ActivityAlert.play, ActivityAlert.transport, ActivityAlert.takoInFront) = saved }
        var played: [String] = []
        let transport = Transport()
        ActivityAlert.play = { played.append($0) }
        ActivityAlert.transport = { transport }
        ActivityAlert.takoInFront = { false }
        let center = PaneToastCenter()
        center.schedule = { _, _ in }

        surface.commandStarted(at: 1_000)
        surface.commandEnded(exitCode: 0, now: 1_010)
        #expect(surface.commandFinishSignals == 1)
        center.statusChanged(surface, to: .done)
        #expect(transport.added.isEmpty && played.isEmpty, "the end was signalled twice")
        #expect(center.toasts.count == 1, "the toast still shows")

        // The next news, with no command-finish signal of its own, is announced.
        center.statusChanged(surface, to: .error)
        #expect(transport.added.count == 1)
    }
}
