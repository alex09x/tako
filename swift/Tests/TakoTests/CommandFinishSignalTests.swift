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
import Foundation
import Testing
@testable import Tako


@MainActor
private func app(_ config: String) throws -> (Tako.App, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tako")
    try config.write(to: url, atomically: true, encoding: .utf8)
    return (Tako.App(configPath: url.path), url)
}

@Suite
@MainActor
struct CommandFinishSignalTests {
    @Test func durationsParseUpstreamsSyntax() {
        #expect(Tako.parseDuration("5s") == .seconds(5))
        #expect(Tako.parseDuration("1m30s") == .seconds(90))
        #expect(Tako.parseDuration("500ms") == .milliseconds(500))
        #expect(Tako.parseDuration("2h") == .seconds(7200))
        #expect(Tako.parseDuration("10") == .seconds(10))
        #expect(Tako.parseDuration("0") == .zero)
        #expect(Tako.parseDuration("") == nil)
        #expect(Tako.parseDuration("5x") == nil)
        #expect(Tako.parseDuration("s") == nil)
        #expect(Tako.parseDuration("-5s") == nil)
        // Out of range must not trap converting to milliseconds.
        #expect(Tako.parseDuration("10000000000000000h") == nil)
        #expect(Tako.parseDuration("1e300") == nil)
        #expect(Tako.parseDuration("inf") == nil)
        #expect(Tako.parseDuration("nan") == nil)
    }

    @Test func onlyMarkedCommandsLongEnoughAndUnwatchedSignal() {
        let after = Duration.seconds(5)
        // No start mark: nothing is known about how long it ran.
        #expect(!Tako.commandFinishShouldSignal(mode: .always, ran: nil, after: after, focused: false))
        #expect(!Tako.commandFinishShouldSignal(mode: .always, ran: 4.9, after: after, focused: false))
        #expect(Tako.commandFinishShouldSignal(mode: .always, ran: 5, after: after, focused: true))
        #expect(!Tako.commandFinishShouldSignal(mode: .never, ran: 60, after: after, focused: false))
        #expect(Tako.commandFinishShouldSignal(mode: .unfocused, ran: 60, after: after, focused: false))
        #expect(!Tako.commandFinishShouldSignal(mode: .unfocused, ran: 60, after: after, focused: true))
    }

    @Test func actionsFollowUpstreamsWords() {
        typealias A = Tako.Config.NotifyOnCommandFinishAction
        #expect(A(parsing: nil) == .bell)
        #expect(A(parsing: "notify") == [.bell, .notify])
        #expect(A(parsing: "no-bell,notify") == .notify)
        #expect(A(parsing: "no-bell") == [])
        #expect(A(parsing: " notify , no-bell , nonsense") == .notify)
    }

    @Test func theKeysAreReadAndDefaultToOff() throws {
        let (plain, a) = try app("")
        defer { try? FileManager.default.removeItem(at: a) }
        #expect(plain.config.notifyOnCommandFinish == .never)
        #expect(plain.config.notifyOnCommandFinishAfter == .seconds(5))
        #expect(plain.config.notifyOnCommandFinishAction == .bell)

        let (set, b) = try app("""
            notify-on-command-finish = unfocused
            notify-on-command-finish-after = 1m
            notify-on-command-finish-action = no-bell,notify
            """)
        defer { try? FileManager.default.removeItem(at: b) }
        #expect(set.config.notifyOnCommandFinish == .unfocused)
        #expect(set.config.notifyOnCommandFinishAfter == .seconds(60))
        #expect(set.config.notifyOnCommandFinishAction == .notify)

        let (bad, c) = try app("notify-on-command-finish = sometimes\nnotify-on-command-finish-after = soon")
        defer { try? FileManager.default.removeItem(at: c) }
        #expect(bad.config.notifyOnCommandFinish == .never)
        #expect(bad.config.notifyOnCommandFinishAfter == .seconds(5))
    }

    @Test func theNotificationSaysHowItEndedAndWhere() {
        let failed = Tako.commandFinishContent(exitCode: 2, ran: 42, title: "~/src/tako")
        #expect(failed.title == "Command failed (exit 2)")
        #expect(failed.body.contains("~/src/tako"))
        #expect(failed.body.contains("42"))
        #expect(Tako.commandFinishContent(exitCode: 0, ran: 3, title: "").title == "Command finished")
        #expect(Tako.commandFinishContent(exitCode: nil, ran: 3, title: "").title == "Command finished")
    }

    /// What a surface does with its shell's marks. (Driving them through a
    /// real shell is not possible here: the parser hands events to the main
    /// thread synchronously, and a test holds the main thread.)
    @Test func aSurfaceSignalsALongMarkedCommandOnlyWhenAsked() throws {
        let (on, a) = try app("""
            notify-on-command-finish = always
            notify-on-command-finish-after = 2s
            notify-on-command-finish-action = no-bell
            """)
        defer { try? FileManager.default.removeItem(at: a) }
        let surface = Tako.SurfaceView(on, baseConfig: nil)
        defer { surface.close() }
        let now: TimeInterval = 1_000

        surface.commandStarted(at: now - 10)
        surface.commandEnded(exitCode: 3, now: now)
        #expect(surface.commandFinishSignals == 1)

        // Too short.
        surface.commandStarted(at: now - 1)
        surface.commandEnded(exitCode: 0, now: now)
        #expect(surface.commandFinishSignals == 1)

        // An end with no start mark before it.
        surface.commandEnded(exitCode: 0, now: now)
        #expect(surface.commandFinishSignals == 1)

        let (off, b) = try app("notify-on-command-finish-action = no-bell")
        defer { try? FileManager.default.removeItem(at: b) }
        let quiet = Tako.SurfaceView(off, baseConfig: nil)
        defer { quiet.close() }
        quiet.commandStarted(at: now - 60)
        quiet.commandEnded(exitCode: 1, now: now)
        #expect(quiet.commandFinishSignals == 0)
    }
}
