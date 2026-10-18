/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// A quiet program's activity, sampled once a second while it runs. Nothing
/// is sampled for a batch job or between commands, and a sample that finds
/// nothing new publishes nothing.
extension Tako.CrabTracker {
    /// Seconds of output the rate and "flowing" look back over.
    static let liveWindow = 3

    func startLive() {
        guard live == nil else { return }
        liveSamples = []
        liveQuietSeconds = 0
        live = Tako.LiveActivity(program: liveProbe?.program, detail: liveProbe?.detail)
        _ = liveProbe?.takeOutputLines()
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLive() }
        }
    }

    func stopLive() {
        liveTimer?.invalidate()
        liveTimer = nil
        liveSamples = []
        if live != nil { live = nil }
    }

    /// One second of output. Internal so a test can drive it.
    func sampleLive() {
        guard let current = live else { return }
        let lines = liveProbe?.takeOutputLines() ?? 0
        liveSamples.append(lines)
        if liveSamples.count > Self.liveWindow { liveSamples.removeFirst() }
        liveQuietSeconds = lines > 0 ? 0 : liveQuietSeconds + 1
        let recent = liveSamples.reduce(0, +)
        var next = current
        next.isFlowing = recent > 0
        next.linesPerSecond = Int((Double(recent) / Double(liveSamples.count)).rounded())
        if lines > 0 { next.pulses &+= 1 }
        // Whole minutes: a quiet label changes once a minute, and a program
        // that prints nothing publishes nothing in between.
        next.quietSeconds = next.isFlowing ? 0 : (liveQuietSeconds / 60).rounded(.down) * 60
        if next != current { live = next }
    }
}
