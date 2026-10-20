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

extension Tako {
    /// What a quiet program -- ssh, vim, `tail -f`, a dev server -- is doing
    /// for its tab (Sessions UI 5a). It is not working, so it shows the data
    /// instead: a ring that answers each burst of output, how long it has
    /// been quiet otherwise. Never a number that changes every second.
    struct LiveActivity: Equatable, Sendable {
        /// The program, as the command line names it: `ssh`, `tail`, `npm`.
        var program: String?
        /// Where it runs, when that is not the pane's directory: ssh's host.
        var detail: String?
        /// Output lines a second over the last few seconds.
        var linesPerSecond = 0
        /// Whether output arrived in the last few seconds.
        var isFlowing = false
        /// Seconds since the last output, or since the program started.
        var quietSeconds: TimeInterval = 0
        /// Bumped once for every second that brought output: each bump is
        /// one ripple of the ring.
        var pulses = 0

        /// Below this the rate is noise and the program's name says more.
        static let rateThreshold = 2

        /// The rate while the output is dense: "38/s". For takoctl only: in
        /// a tab it was one more number changing every second, as the timer was.
        var rateLabel: String? {
            isFlowing && linesPerSecond >= Self.rateThreshold ? "\(linesPerSecond)/s" : nil
        }

        /// What stands where a timer would: the program.
        var metaLabel: String? { program }

        /// How long it has been quiet, in whole minutes: "quiet 4m".
        var quietLabel: String {
            let minutes = Int(quietSeconds / 60)
            if minutes < 1 { return "quiet" }
            if minutes < 60 { return "quiet \(minutes)m" }
            return "quiet \(minutes / 60)h \(minutes % 60)m"
        }
    }

    /// How a tracker reads the pane it belongs to while a quiet program
    /// runs, injected so a test can drive it.
    struct LiveProbe {
        /// Output lines since the last call.
        var takeOutputLines: () -> Int
        var isAlternateScreen: () -> Bool = { false }
        var program: String?
        var detail: String?
    }

    /// Counts the lines a pane prints, on the queue that parses them. The
    /// echo of the user's own typing is not output: a line that arrives
    /// within `echoWindow` of a keystroke is not counted, or every key in
    /// ssh or vim would ripple the ring. Nor is a program drawing itself
    /// again because the pane changed size: Tako asked for that, and a
    /// quiet agent redrawn is still quiet.
    final class OutputActivityMeter: @unchecked Sendable {
        static let echoWindow: TimeInterval = 0.15
        static let redrawWindow: TimeInterval = 1

        private let lock = NSLock()
        private var lines = 0
        private var lastInputAt: TimeInterval = -.infinity
        private var redrawUntil: TimeInterval = -.infinity

        func noteInput(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            lock.withLock { lastInputAt = now }
        }

        /// The pane changed size: what the program prints in the next
        /// `redrawWindow` is its redraw.
        func noteResize(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            lock.withLock { redrawUntil = now + Self.redrawWindow }
        }

        func noteOutput(_ data: Data, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            let newlines = Self.countNewlines(data)
            guard newlines > 0 else { return }
            lock.withLock {
                guard now - lastInputAt > Self.echoWindow, now >= redrawUntil else { return }
                lines += newlines
            }
        }

        /// memchr: this runs on every chunk a pane prints.
        static func countNewlines(_ data: Data) -> Int {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                var count = 0
                var offset = 0
                while offset < raw.count, let hit = memchr(base + offset, 0x0A, raw.count - offset) {
                    count += 1
                    offset = base.distance(to: UnsafeRawPointer(hit)) + 1
                }
                return count
            }
        }

        /// Lines counted since the last call.
        func take() -> Int {
            lock.withLock {
                defer { lines = 0 }
                return lines
            }
        }
    }
}
