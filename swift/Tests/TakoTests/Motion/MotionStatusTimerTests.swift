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
@testable import Tako

/// The timers that switch what a ring shows, left to fire on their own: a
/// command turns working once it has run 3 s, an outcome in the focused tab
/// goes out 2 s after it shows, a quiet program is sampled once a second,
/// and a command the shell did not name is looked up while it starts. Each
/// runs faster here; its spec interval is held beside it.
@Suite(.serialized) @MainActor
struct MotionStatusTimerTests {
    private func wait(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    @Test func theClocksAreTheSpecs() {
        let tracker = Tako.CrabTracker()
        #expect(Tako.CrabTracker.minimumVisibleDuration == MotionSpec.minimumVisible, "только если команда идёт > 3s")
        #expect(tracker.linger == MotionSpec.focusedLinger, "гаснут через 2s")
        #expect(tracker.liveSampleInterval == 1, "sampled once a second: a ripple at most once a second")
        #expect(tracker.tickInterval <= 0.5, "a command shows within half a second of its 3 s")
    }

    @Test func aCommandTurnsWorkingWhenItsTickerFindsItHasRun3s() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.tickInterval = 0.02
        tracker.commandStarted()
        now += 2.9
        await wait(0.1)
        #expect(tracker.state == .idle, "working before 3 s")
        now += 0.2
        await wait(0.1)
        #expect(tracker.state == .running, "the ticker did not turn it working after 3 s")
        tracker.commandEnded(exitCode: 0)
    }

    @Test func anOutcomeInTheFocusedTabGoesOutWhenItsTimerFires() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.isFocused = true
        tracker.linger = 0.05
        tracker.commandStarted()
        now += 4
        tracker.commandEnded(exitCode: 0)
        #expect(tracker.state == .succeeded)
        #expect(tracker.isFadePending)
        await wait(0.2)
        #expect(tracker.state == .idle, "done did not go out when its timer fired")
        #expect(!tracker.unread)
    }

    @Test func aQuietProgramIsSampledByItsOwnTimer() async throws {
        let tracker = Tako.CrabTracker()
        tracker.liveSampleInterval = 0.03
        tracker.commandStarted(kind: .quiet, probe: Tako.LiveProbe(takeOutputLines: { 4 }, program: "tail"))
        defer { tracker.commandEnded(exitCode: nil) }
        let first = try #require(tracker.live).pulses
        await wait(0.2)
        let live = try #require(tracker.live)
        #expect(live.pulses > first, "no sample was taken")
        #expect(live.isFlowing)
    }

    @Test func aCommandTheShellDidNotNameGoesLiveWhenWhatRunsInFrontIsQuiet() async {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        surface.frontCommandProbe = { "tail -f /var/log/system.log" }
        surface.shellStartedCommand("")
        #expect(surface.crab.live == nil, "an unnamed command starts as a job")
        await wait(0.8)
        #expect(surface.crab.live != nil, "the process in front was not looked up: tail -f still spins as working")
        surface.crab.commandEnded(exitCode: nil)
    }
}
