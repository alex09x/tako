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

    /// `quietSince`: when the program last printed, if that was before
    /// now -- a program Tako finds running after a restart.
    func startLive(quietSince: Date? = nil) {
        guard live == nil else { return }
        liveSamples = []
        let start = now()
        liveSampledAt = start
        liveLastOutputAt = min(quietSince ?? start, start)
        var activity = Tako.LiveActivity(program: liveProbe?.program, detail: liveProbe?.detail)
        activity.quietSeconds = Self.wholeMinutes(since: liveLastOutputAt, at: start)
        live = activity
        _ = liveProbe?.takeOutputLines()
        tellQuietSince(at: start)
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLive() }
        }
    }

    func stopLive() {
        liveTimer?.invalidate()
        liveTimer = nil
        liveSamples = []
        liveSampledAt = nil
        liveLastOutputAt = nil
        liveQuietSinceToldAt = nil
        if live != nil {
            live = nil
            onQuietSince?(nil)
        }
    }

    /// One second of output. Internal so a test can drive it.
    func sampleLive() {
        guard let current = live else { return }
        let at = now()
        let lines = liveProbe?.takeOutputLines() ?? 0
        // A sample that waited out a nap or a sleep does not bring that time
        // into the rate: one that found nothing covers a second at most,
        // one that found lines no more than the window.
        let earliest = at - TimeInterval(lines > 0 ? Self.liveWindow : 1)
        liveSamples.append((from: max(liveSampledAt ?? at, earliest), to: at, lines: lines))
        liveSampledAt = at
        // The last few seconds of the clock, and no more samples than the
        // timer takes in them.
        liveSamples.removeAll { $0.to <= at - TimeInterval(Self.liveWindow) }
        if liveSamples.count > Self.liveWindow { liveSamples.removeFirst(liveSamples.count - Self.liveWindow) }
        if lines > 0 {
            liveLastOutputAt = at
            // Once a minute is enough: the label counts whole minutes.
            if liveQuietSinceToldAt.map({ at.timeIntervalSince($0) >= 60 }) ?? true { tellQuietSince(at: at) }
        }
        let recent = liveSamples.reduce(0) { $0 + $1.lines }
        var next = current
        // By the clock too: samples a held-back timer took minutes apart
        // are not the last few seconds.
        next.isFlowing = recent > 0
            && liveLastOutputAt.map { at.timeIntervalSince($0) < TimeInterval(Self.liveWindow) } ?? false
        // Over the time the samples really cover: a timer held back to one
        // sample in two seconds took two seconds of lines in each. A sample
        // is never taken to cover less than the second it is meant to.
        let span = max(liveSamples.first.map { at.timeIntervalSince($0.from) } ?? 0, Double(liveSamples.count))
        next.linesPerSecond = Int((Double(recent) / span).rounded())
        if lines > 0 { next.pulses &+= 1 }
        // Whole minutes: a quiet label changes once a minute, and a program
        // that prints nothing publishes nothing in between.
        next.quietSeconds = next.isFlowing ? 0 : Self.wholeMinutes(since: liveLastOutputAt, at: at)
        if next != current { live = next }
    }

    private func tellQuietSince(at moment: Date) {
        guard let since = liveLastOutputAt else { return }
        liveQuietSinceToldAt = moment
        onQuietSince?(since)
    }

    static func wholeMinutes(since: Date?, at moment: Date) -> TimeInterval {
        guard let since else { return 0 }
        return (max(0, moment.timeIntervalSince(since)) / 60).rounded(.down) * 60
    }
}
