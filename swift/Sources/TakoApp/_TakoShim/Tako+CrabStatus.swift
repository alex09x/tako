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

extension Tako.CrabTracker {
    /// Whether a fade is armed, for tests.
    var isFadePending: Bool { successTimer?.isValid == true }
    /// When the armed fade goes off, for tests.
    var fadeDue: Date? { isFadePending ? successTimer?.fireDate : nil }

    /// What the fade does when it fires. Internal so a test can fire it
    /// without waiting on a real timer.
    func fadeSeenOutcome() {
        guard isFocused else { return }
        let acknowledgedExplicit = explicitStatus?.status == .done || explicitStatus?.status == .error
        if acknowledgedExplicit {
            explicitStatus = (status: .idle, text: nil)
        }
        if signalStatus == .done || signalStatus == .error {
            signalStatus = .idle
        }
        switch state {
        case .succeeded, .failed:
            state = .idle
        default:
            break
        }
        if unread { unread = false }
        recomputeEffectiveStatus()
        if acknowledgedExplicit {
            onAcknowledgedOutcome?()
        }
    }

    func bellRang() {
        // Never override something more important.
        if Tako.CrabState.attention.priority > state.priority { state = .attention }
        if !unread { unread = true }
    }

    func progressReported(state: UInt8, value: UInt8?) {
        let nextState: ProgressState
        let nextValue: Int?
        switch state {
        case 0:
            nextState = .none
            nextValue = nil
        case 1:
            nextState = .normal
            nextValue = value.map(Int.init)
        case 2:
            nextState = .error
            nextValue = value.map(Int.init)
        case 3:
            nextState = .indeterminate
            nextValue = value.map(Int.init)
        case 4:
            nextState = .paused
            nextValue = value.map(Int.init)
        default:
            nextState = .none
            nextValue = nil
        }
        if progressState != nextState { progressState = nextState }
        if progress != nextValue { progress = nextValue }
    }

    func connectionLost() {
        stopLive()
        if progress != nil { progress = nil }
        if progressState != .none { progressState = .none }
        signalStatus = .disconnected
        if state != .ghost { state = .ghost }
        if !unread { unread = true }
        recomputeEffectiveStatus()
    }

    func reconnecting() {
        if state != .reconnecting { state = .reconnecting }
    }

    /// Set explicit pane status, with optional text and TTL.
    func setStatus(_ statusString: String, text: String?, ttl: TimeInterval? = nil) {
        guard let parsed = Tako.PaneStatus.parse(statusString) else { return }
        setStatus(parsed, text: text, ttl: ttl)
    }

    /// Apply an `OSC 7501` status table snapshot to `CrabTracker` with equality guards.
    func applyProgramStatusSnapshot(_ snapshot: TerminalProgramStatusSnapshot) {
        let wasActive = osc7501StatusActive
        osc7501StatusActive = snapshot.osc7501Active

        guard let effective = snapshot.effective else {
            lastProgramStatusNotificationKey = nil
            if wasActive || snapshot.osc7501Active {
                clearStatus()
                progressReported(state: 0, value: nil)
            }
            return
        }

        let mappedStatus: Tako.PaneStatus
        let nextProgressState: ProgressState
        let nextProgress: Int?

        switch effective.state {
        case .working:
            mappedStatus = .working
            if let pct = effective.progress {
                nextProgressState = .normal
                nextProgress = Int(pct)
            } else {
                nextProgressState = .indeterminate
                nextProgress = nil
            }
        case .blocked:
            mappedStatus = effective.kind == .permission ? .needsApproval : .waitingForInput
            nextProgressState = .paused
            nextProgress = effective.progress.map(Int.init) ?? 100
        case .done:
            mappedStatus = .done
            nextProgressState = .none
            nextProgress = nil
        case .error:
            mappedStatus = .error
            nextProgressState = .error
            nextProgress = 100
        case .idle:
            mappedStatus = .idle
            nextProgressState = .none
            nextProgress = nil
        }

        let text = effective.displayMessage
        let sanitized = text.flatMap(Tako.sanitizeStatusText)
        let explicitUnchanged = explicitStatus?.status == mappedStatus && explicitStatus?.text == sanitized
        if !explicitUnchanged {
            setStatus(mappedStatus, text: text)
        }
        if progressState != nextProgressState { progressState = nextProgressState }
        if progress != nextProgress { progress = nextProgress }

        if ![TerminalProgramStatusState.blocked, .done, .error].contains(effective.state) {
            lastProgramStatusNotificationKey = nil
        }
    }

    /// The user pressed Escape or Ctrl-C in this pane.
    func userInterrupted() {
        guard let explicit = explicitStatus else { return }
        switch explicit.status {
        case .working, .running, .needsApproval, .waitingForInput:
            setStatus(.idle, text: nil)
            progressReported(state: 0, value: nil)
        default:
            break
        }
    }

    /// Clears explicit status, reverting to signal-derived state.
    func clearStatus() {
        ttlTimer?.invalidate()
        ttlTimer = nil
        explicitStatus = nil
        if statusText != nil { statusText = nil }
        if statusExpiresAt != nil { statusExpiresAt = nil }
        recomputeEffectiveStatus()
    }

    /// Called when TTL timer fires: status expires to unknown.
    func ttlExpired() {
        ttlTimer?.invalidate()
        ttlTimer = nil
        explicitStatus = (status: .unknown, text: nil)
        if statusText != nil { statusText = nil }
        if statusExpiresAt != nil { statusExpiresAt = nil }
        recomputeEffectiveStatus()
    }

    /// Remaining seconds on the TTL timer, or nil if none is armed.
    public var remainingTTL: TimeInterval? {
        guard let expiresAt = statusExpiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSince(now())
        return max(0, remaining)
    }

    func recomputeEffectiveStatus() {
        if let explicit = explicitStatus {
            if paneStatus != explicit.status { paneStatus = explicit.status }
            if statusText != explicit.text { statusText = explicit.text }
            let nextCrab = explicit.status.crabState
            if state != nextCrab { state = nextCrab }
        } else {
            if paneStatus != signalStatus { paneStatus = signalStatus }
            if statusText != nil { statusText = nil }
            if case .failed = state, signalStatus == .error {
                // keep failed state
            } else if case .succeeded = state {
                // keep succeeded state
            } else if case .ghost = state, signalStatus == .disconnected {
                // keep ghost state
            } else if case .running = state, signalStatus == .running {
                // keep running state
            } else if signalStatus == .running {
                if state != .idle { state = .idle }
            } else {
                let nextCrab = paneStatus.crabState
                if state != nextCrab { state = nextCrab }
            }
        }
    }

    /// The user looked at this tab/pane: clear what was waiting for them.
    func focused() {
        isFocused = true
        if unread { unread = false }
        let acknowledgedExplicit = explicitStatus?.status == .done || explicitStatus?.status == .error
        if acknowledgedExplicit {
            explicitStatus = (status: .idle, text: nil)
            if progressState == .error {
                progressState = .none
                progress = nil
            }
        }
        if signalStatus == .done || signalStatus == .error {
            signalStatus = .idle
        }
        switch state {
        case .succeeded, .failed, .attention:
            state = .idle
        default:
            break
        }
        recomputeEffectiveStatus()
        if acknowledgedExplicit {
            onAcknowledgedOutcome?()
        }
    }

    func unfocused() {
        isFocused = false
    }

    /// Advance the running clock. Public so a test can drive it without
    /// waiting on a real timer.
    func tick() {
        guard let startedAt else { return }
        if commandKind == .batch, liveProbe?.isAlternateScreen() == true { settleQuiet() }
        let ran = now().timeIntervalSince(startedAt)
        guard ran >= Self.minimumVisibleDuration else { return }
        if explicitStatus != nil {
            if elapsed != ran { elapsed = ran }
            return
        }
        guard commandKind == nil || commandKind == .batch else { return }
        if elapsed != ran { elapsed = ran }
        if Tako.CrabState.running.priority > state.priority || state == .idle {
            state = .running
        }
    }

    func commandIdentified(as kind: Tako.CommandKind, probe: Tako.LiveProbe) {
        guard kind != .batch, commandKind == .batch, startedAt != nil else { return }
        liveProbe = probe
        settleQuiet(as: kind)
    }

    func settleQuiet(as kind: Tako.CommandKind = .quiet) {
        commandKind = kind
        if explicitStatus == nil {
            ticker?.invalidate()
            ticker = nil
            if elapsed != nil { elapsed = nil }
        }
        startLive()
        if state == .running { state = .idle }
        signalStatus = .idle
    }

    func setElapsed(_ seconds: TimeInterval?) {
        if elapsed != seconds { elapsed = seconds }
    }
}
