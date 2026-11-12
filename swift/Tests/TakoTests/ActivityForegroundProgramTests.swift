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

/// A program that reports its own status (OSC 7501, e.g. an agent) in a tab
/// out of sight while Tako is in front: Tako plays the chosen sound itself,
/// once, and the program's notification goes out silent -- it does not
/// depend on macOS notifications being allowed. In the background the
/// notification carries the sound, as before. The route is decided when the
/// event happens and written into the request, so a request that macOS
/// presents later, after the window context changed, never adds a second sound.
@Suite(.serialized) @MainActor
struct ActivityForegroundProgramTests {
    private final class Transport: ActivityNotificationTransport {
        var added: [UNNotificationRequest] = []
        func add(_ request: UNNotificationRequest) { added.append(request) }
        func removePending(_ ids: [String]) {}
        func removeDelivered(_ ids: [String]) {}
    }

    private struct Run {
        var played: [String] = []
        var native: [UNNotificationRequest] = []
        var inferred: [UNNotificationRequest] = []
    }

    /// Feeds a real OSC 7501 report to an unfocused surface, then lets the
    /// toast center see the status change as the app does.
    private func report(_ state: String, front: Bool, prefs: [String: String] = [:]) throws -> Run {
        TakoTerminalNSView.isMetalDisabledForTesting = true
        var config = Tako.SurfaceConfiguration()
        config.allowsSessionPersistence = false
        config.program = ["/usr/bin/true"]
        let surface = Tako.SurfaceView(nil, baseConfig: config, uuid: UUID(), theme: nil)
        surface.onExit = nil; surface.pty?.terminate(); surface.pty = nil; surface.resetTerminal()
        defer { surface.close() }
        surface.crab.isFocused = false

        let saved = (ActivityAlert.play, ActivityAlert.transport, ActivityAlert.takoInFront, Tako.onNotificationPosted,
                     DesktopPresentation.shared.preferences)
        defer {
            (ActivityAlert.play, ActivityAlert.transport, ActivityAlert.takoInFront, Tako.onNotificationPosted) =
                (saved.0, saved.1, saved.2, saved.3)
            DesktopPresentation.shared.apply(saved.4)
        }
        DesktopPresentation.shared.apply(DesktopPreferences { prefs[$0] })
        var run = Run()
        let transport = Transport()
        ActivityAlert.play = { run.played.append($0) }
        ActivityAlert.transport = { transport }   // nothing reaches macOS: authorization off or unavailable
        ActivityAlert.takoInFront = { front }
        Tako.onNotificationPosted = { if $0.identifier.contains("osc7501") { run.native.append($0) } }
        NotificationCoalescer.shared.reset()

        let msg = Data("finished".utf8).base64EncodedString()
        surface.feed(data: Data("\u{1b}]7501;state=\(state):id=t:kind=task:app=muse:msg=\(msg)\u{1b}\\".utf8))
        let center = PaneToastCenter()
        center.schedule = { _, _ in }
        center.statusChanged(surface, to: surface.crab.paneStatus)
        run.inferred = transport.added
        return run
    }

    @Test func inFrontTheProgramsNewsPlaysTheChosenSoundOnce() throws {
        let run = try report("done", front: true)
        #expect(run.played == ["Hero"], "Tako in front, a tab out of sight reported done: \(run.played)")
        let native = try #require(run.native.first, "the program's own notification is still scheduled")
        #expect(native.content.sound == nil, "the notification would add a second sound")
        #expect(run.inferred.isEmpty, "a second, inferred notification was scheduled")

        let blocked = try report("blocked", front: true, prefs: ["activity-sound-needs-you": "Pop"])
        #expect(blocked.played == ["Pop"], "the chosen sound for needs-you")
    }

    @Test func inTheBackgroundTheNotificationCarriesTheSound() throws {
        let run = try report("done", front: false)
        #expect(run.played.isEmpty, "Tako played a sound in the background")
        let native = try #require(run.native.first)
        #expect(native.content.sound != nil, "the background notification lost its sound")
        #expect(run.inferred.isEmpty)
    }

    @Test func muteNeverAndNoneStaySilentInFront() throws {
        for prefs in [["activity-alert": "never"], ["activity-sound-done": "none"]] {
            let run = try report("done", front: true, prefs: prefs)
            #expect(run.played.isEmpty, "\(prefs) played \(run.played)")
            #expect(run.native.first?.content.sound == nil)
        }
    }

    /// The sound is in the request, decided when the event happened: what
    /// macOS presents later plays exactly that, whatever is in front by then.
    @Test func aRequestPresentedAfterTheContextChangedKeepsItsOwnRoute() throws {
        let background = try report("done", front: false)   // scheduled while Tako was behind
        let foreground = try report("done", front: true)    // scheduled while Tako was in front
        // willPresent shows both with the same options; only content.sound decides what is heard.
        #expect(background.native.first?.content.sound != nil && background.played.isEmpty, "background: macOS plays it, once")
        #expect(foreground.native.first?.content.sound == nil && foreground.played.count == 1, "foreground: Tako played it, once")
        // An explicit notification (OSC 9/777/99) is not an activity sound: it keeps its urgency's sound.
        let explicit = Tako.buildNotificationContent(title: "build", body: "", surfaceId: UUID(), paneTitle: "", pwd: nil, command: nil,
                                                     id: "explicit", urgency: 1)
        ActivitySoundChoice.byUrgency.apply(to: explicit)
        #expect(explicit.sound == .default)
    }
}
