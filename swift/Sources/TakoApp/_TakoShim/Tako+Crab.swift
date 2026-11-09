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

// The crab indicator that sits in each tab.
//
// The brand's design gives it seven states and a strict priority between
// them, so the state lives here rather than being inferred at draw time:
// a tab's crab has to survive going to the background, and a background
// tab that failed must stay red until the user looks at it.

extension Tako {
    enum CrabState: Equatable {
        /// No command running, or one that finished too fast to be worth
        /// showing.
        case idle
        /// A command has been running long enough to show.
        case running
        /// The last command exited zero. Reverts to `idle` after a beat in
        /// the focused tab; in a background tab it waits to be seen.
        case succeeded
        /// The last command failed. Holds until the tab is focused.
        case failed(code: Int32?)
        /// The terminal rang the bell, or sent a notification.
        case attention
        /// Reconnecting an ssh session.
        case reconnecting
        /// The connection dropped; the screen is kept as it was.
        case ghost

        /// When several could apply at once, the design fixes this order.
        var priority: Int {
            switch self {
            case .ghost: return 6
            case .failed: return 5
            case .running: return 4
            case .attention: return 3
            case .succeeded: return 2
            case .idle: return 1
            case .reconnecting: return 0
            }
        }

        // Its colours, figure and motion: Tako.CrabPainter and Tako.CrabLayer.
    }

    struct ProgramStatusNotificationKey: Equatable, Sendable {
        let id: String
        let state: TerminalProgramStatusState
        let kind: TerminalProgramStatusBlockedKind?
        let title: String?
        let msg: String?
    }

    /// Tracks one surface's command lifecycle and turns it into a crab state,
    /// pane status, and elapsed time.
    @MainActor
    final class CrabTracker: ObservableObject {
        /// A command shorter than this never shows: `ls` and `cd` should not
        /// make the indicator twitch.
        static let minimumVisibleDuration: TimeInterval = 3

        /// How long a success or a failure stays on the surface in a focused
        /// tab (Spec 1b: "done" and "failed" fade after 2 s on the active
        /// tab, and hold until focus on a background one).
        static let successLinger: TimeInterval = 2

        /// The tracker's own clocks, the spec's by default; a test runs them
        /// faster to watch them fire.
        var tickInterval: TimeInterval = 0.5
        var linger: TimeInterval = successLinger
        var liveSampleInterval: TimeInterval = 1

        @Published var state: CrabState = .idle
        public typealias ProgressState = TakoTerminalNSView.ProgressState

        /// Seconds since the running command started, or nil when idle.
        @Published var elapsed: TimeInterval?
        /// 0...100 from OSC 9;4 or OSC 7501, when the program reports it.
        @Published public internal(set) var progress: Int?
        /// The progress state from OSC 9;4 or OSC 7501.
        @Published public internal(set) var progressState: ProgressState = .none
        /// Set when something happened that the user has not looked at.
        @Published var unread = false

        /// Explicit pane status model (B1 / OSC 7501).
        @Published public internal(set) var paneStatus: PaneStatus = .idle
        @Published public internal(set) var statusText: String?
        @Published public internal(set) var statusExpiresAt: Date?

        var signalStatus: PaneStatus = .idle {
            didSet {
                guard signalStatus != oldValue else { return }
                recomputeEffectiveStatus()
            }
        }
        var explicitStatus: (status: PaneStatus, text: String?)?
        var ttlTimer: Timer?
        var osc7501StatusActive = false
        var lastProgramStatusSnapshot: TerminalProgramStatusSnapshot?
        var lastProgramStatusNotificationKey: ProgramStatusNotificationKey?
        var activeProgramStatusNotificationIDs: Set<String> = []
        var onAcknowledgedOutcome: (() -> Void)?
        /// False while a restored status is applied (checkpoint, reset): what
        /// changes then is state brought back, not news, so nothing announces it.
        var announcesStatusChanges = true

        /// Whether this pane is currently focused / looked at by user.
        public var isFocused: Bool = false

        var startedAt: Date?
        /// What the running command is; nil when none runs.
        var commandKind: CommandKind?
        /// The pane, as the running command's tracking reads it: whether it
        /// shows its alternate screen -- a job that turns full-screen (`git
        /// log` paging, `make menuconfig`) is one the user is inside,
        /// whatever its name said -- and what it prints.
        var liveProbe: LiveProbe?
        /// What a quiet program is doing (Sessions UI 5a); nil while none
        /// runs. See Tako+CrabLive.swift.
        @Published var live: LiveActivity?
        var liveTimer: Timer?
        /// The last few samples: the lines that arrived between `from` and `to`.
        var liveSamples: [(from: Date, to: Date, lines: Int)] = []
        /// When the quiet program last printed, or started: a moment on the
        /// clock, not a count of ticks, so a timer App Nap holds back or a
        /// Mac asleep does not make the quiet look shorter than it is.
        var liveLastOutputAt: Date?
        /// When the last sample was taken: where the next one starts.
        var liveSampledAt: Date?
        /// Told that moment, at most once a minute while output arrives, so
        /// it outlives a restart of Tako; told nil when the program ends.
        var onQuietSince: ((Date?) -> Void)?
        var liveQuietSinceToldAt: Date?
        var ticker: Timer?
        var successTimer: Timer?

        /// Injected so tests can run without a real clock.
        let now: () -> Date

        init(now: @escaping () -> Date = Date.init) {
            self.now = now
        }

        convenience init(clock: @escaping () -> Date) {
            self.init(now: clock)
        }

        deinit {
            ticker?.invalidate()
            successTimer?.invalidate()
            ttlTimer?.invalidate()
            liveTimer?.invalidate()
        }

        func promptMark() {
            if !unread {
                signalStatus = .idle
            }
            recomputeEffectiveStatus()
        }

        /// `quietSince`: for a quiet program Tako finds running after a
        /// restart, when it last printed, as the last Tako recorded it.
        func commandStarted(kind: CommandKind = .batch, probe: LiveProbe? = nil, quietSince: Date? = nil) {
            startedAt = now()
            commandKind = kind
            liveProbe = probe
            stopLive()
            if elapsed != nil { elapsed = nil }
            if progress != nil { progress = nil }
            successTimer?.invalidate()
            signalStatus = kind == .batch ? .running : .idle
            if unread { unread = false }
            if explicitStatus?.status == .done || explicitStatus?.status == .idle {
                explicitStatus = nil
            }
            recomputeEffectiveStatus()

            // The state only becomes `.running` once the command has lasted
            // long enough to be worth showing. A quiet one never does.
            ticker?.invalidate()
            ticker = nil
            guard kind == .batch else {
                startLive(quietSince: quietSince)
                return
            }
            ticker = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }

        func commandEnded(exitCode: Int32?) {
            // fish reports each end more than once -- the same status again,
            // then one with none at its next prompt. Those end no started
            // command; taken as a short success they wiped a background tab's
            // "failed" or "done" a moment after it showed. An end that starts
            // nothing and says nothing new (no status, or success) is ignored;
            // a failure is still shown.
            if startedAt == nil && (exitCode == nil || exitCode == 0) { return }
            let kind = commandKind ?? .batch
            commandKind = nil
            stopLive()
            liveProbe = nil
            ticker?.invalidate()
            ticker = nil
            let ran = startedAt.map { now().timeIntervalSince($0) }
            startedAt = nil
            if elapsed != nil { elapsed = nil }
            if !osc7501StatusActive || explicitStatus?.status != .error {
                if progress != nil { progress = nil }
                if progressState != .none { progressState = .none }
            }

            if let exitCode, kind.fails(exitCode) {
                signalStatus = .error
                if state != .failed(code: exitCode) { state = .failed(code: exitCode) }
                if !unread { unread = true }
                recomputeEffectiveStatus()
                if isFocused { fadeWhileFocused() }
                return
            }

            // Leaving vim or ssh, or stopping a server, is not news -- unless
            // a TUI agent explicitly reported a terminal/blocked outcome right
            // before exiting, in which case `unread` and `explicitStatus` stay.
            guard kind == .batch else {
                signalStatus = .idle
                if let explicit = explicitStatus,
                   [.done, .error, .needsApproval, .waitingForInput].contains(explicit.status) {
                    recomputeEffectiveStatus()
                } else {
                    if state != .idle { state = .idle }
                    if unread { unread = false }
                    recomputeEffectiveStatus()
                }
                return
            }

            // Shown as done in a focused tab too, for `successLinger`; in a
            // background one it waits to be seen.
            signalStatus = .done
            let shouldBeUnread = !isFocused
            if unread != shouldBeUnread { unread = shouldBeUnread }

            // A command too short to have shown as running should not flash
            // green either.
            guard let ran, ran >= Self.minimumVisibleDuration else {
                signalStatus = .idle
                if state != .idle { state = .idle }
                if unread { unread = false }
                recomputeEffectiveStatus()
                return
            }
            if state != .succeeded { state = .succeeded }
            recomputeEffectiveStatus()
            if isFocused { fadeWhileFocused() }
        }

        /// In the focused tab a finished command's "done" or "failed" is
        /// seen as it happens: it goes quiet after `successLinger`, unless
        /// something newer replaced it or the tab lost focus meanwhile.
        func fadeWhileFocused() {
            successTimer?.invalidate()
            successTimer = Timer.scheduledTimer(withTimeInterval: linger, repeats: false) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.fadeSeenOutcome() }
            }
        }

        /// Set explicit pane status, with optional text and TTL.
        func setStatus(_ status: PaneStatus, text: String?, ttl: TimeInterval? = nil) {
            ttlTimer?.invalidate()
            ttlTimer = nil

            let sanitizedText = text.flatMap(Tako.sanitizeStatusText)
            if status == .done {
                ticker?.invalidate(); ticker = nil; startedAt = nil
                if elapsed != nil { elapsed = nil }
                explicitStatus = (status: .done, text: sanitizedText)
                let nextUnread = !isFocused
                if unread != nextUnread { unread = nextUnread }
                if isFocused { fadeWhileFocused() }
            } else {
                explicitStatus = (status: status, text: sanitizedText)
                if status == .working || status == .running || status == .needsApproval || status == .waitingForInput {
                    if status == .needsApproval || status == .waitingForInput {
                        let nextUnread = !isFocused
                        if unread != nextUnread { unread = nextUnread }
                    }
                    if startedAt == nil { startedAt = now() }
                    if ticker == nil {
                        ticker = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
                            MainActor.assumeIsolated { self?.tick() }
                        }
                    }
                } else {
                    ticker?.invalidate(); ticker = nil; startedAt = nil
                    if elapsed != nil { elapsed = nil }
                }
                if status == .error {
                    let nextUnread = !isFocused
                    if unread != nextUnread { unread = nextUnread }
                    if isFocused { fadeWhileFocused() }
                }
            }
            if statusText != sanitizedText { statusText = sanitizedText }
            if status == .idle || status == .done { quietLive() }

            if let ttl, ttl > 0 {
                let expires = now().addingTimeInterval(ttl)
                if statusExpiresAt != expires { statusExpiresAt = expires }
                ttlTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.ttlExpired()
                    }
                }
            } else if statusExpiresAt != nil {
                statusExpiresAt = nil
            }
            recomputeEffectiveStatus()
        }
    }
}
