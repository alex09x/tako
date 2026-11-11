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

/// A SIGTERM quit that must ask first gets its question and its answer. The
/// quit stand-in does what `AppDelegate.terminate()` and AppKit do for
/// `.terminateLater`: schedule the question and its reply as a main-actor
/// task, then wait for the reply in a nested run loop. The signal's own
/// entry, `handleTerminationSignal`, is called from a main-queue callout, as
/// SIGTERM's dispatch source calls it. No signal is sent and nothing quits.
@MainActor @Suite(.serialized)
struct SigtermQuitTests {
    private func quitBySignal(answer: Bool) async throws -> [String] {
        var outcome: [String] = []
        let saved = AppDelegate.terminateForSignal
        defer { AppDelegate.terminateForSignal = saved }
        AppDelegate.terminateForSignal = {
            var reply: Bool?
            Task { @MainActor in reply = answer }  // the question, answered
            // AppKit waits in its modal-panel mode, one of NSApplication's common
            // modes, so the main queue is serviced there; this test process has no
            // NSApplication run, and the default mode is the one that services it.
            let until = Date().addingTimeInterval(1)
            while reply == nil, Date() < until {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            outcome.append(reply.map { $0 ? "quit" : "cancelled" } ?? "starved")
        }
        DispatchQueue.main.async { AppDelegate.handleTerminationSignal() }
        for _ in 0..<60 where outcome.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        return outcome
    }

    @Test func aQuitBySignalThatAsksGetsItsAnswer() async throws {
        let got = try await quitBySignal(answer: true)
        #expect(got == ["quit"], "outcome: \(got)")
    }

    @Test func aQuitBySignalCanStillBeCancelled() async throws {
        let got = try await quitBySignal(answer: false)
        #expect(got == ["cancelled"], "outcome: \(got)")
    }
}
