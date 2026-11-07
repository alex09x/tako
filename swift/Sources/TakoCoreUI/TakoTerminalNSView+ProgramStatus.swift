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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension TakoTerminalNSView {
    /// Controls whether `OSC 7501 ; ? ST` queues a capability reply on this view's engine.
    public var programStatusProbeReplyEnabled: Bool {
        get { core.isProgramStatusProbeReplyEnabled() }
        set { core.setProgramStatusProbeReplyEnabled(enabled: newValue) }
    }

    /// Current `OSC 7501` status table snapshot.
    public func programStatusSnapshot() -> TerminalProgramStatusSnapshot {
        TerminalProgramStatusSnapshot(ffi: core.programStatusSnapshot())
    }

    /// Notify the engine that the foreground/PTY process exited (`working`/`blocked`/`idle` dropped, `done`/`error` kept).
    public func notifyProgramStatusProcessExited() {
        guard let ffiUpdate = core.programStatusProcessExited() else { return }
        emitDirectProgramStatusLifecycleUpdate(ffiUpdate)
    }

    /// Notify the engine that the user pressed `Esc`/`Ctrl-C` (`working`/`blocked` dropped).
    public func notifyProgramStatusInterrupted() {
        guard let ffiUpdate = core.programStatusInterrupted() else { return }
        emitDirectProgramStatusLifecycleUpdate(ffiUpdate)
    }

    /// Notify the engine that the user acknowledged finished/failed output (`done`/`error` dropped).
    public func notifyProgramStatusAcknowledged() {
        guard let ffiUpdate = core.programStatusAcknowledged() else { return }
        emitDirectProgramStatusLifecycleUpdate(ffiUpdate)
    }

    private func emitDirectProgramStatusLifecycleUpdate(_ ffiUpdate: FfiProgramStatusUpdate) {
        _ = core.drainProgramStatusUpdates(maxUpdates: UInt32.max)
        let snapshot = programStatusSnapshot()
        applyProgramStatusProgressBar(from: snapshot)
        delegate?.terminalView(
            self,
            didUpdateProgramStatus: .updated(TerminalProgramStatusUpdate(ffi: ffiUpdate), snapshot: snapshot)
        )
    }

    func applyProgramStatusProgressBar(from snapshot: TerminalProgramStatusSnapshot) {
        guard let effective = snapshot.effective else {
            if snapshot.osc7501Active {
                updateProgressBar(state: .none, progress: nil)
            }
            return
        }
        switch effective.state {
        case .working:
            if let pct = effective.progress {
                updateProgressBar(state: .normal, progress: Int(pct))
            } else {
                updateProgressBar(state: .indeterminate, progress: nil)
            }
        case .blocked:
            updateProgressBar(state: .paused, progress: effective.progress.map(Int.init) ?? 100)
        case .error:
            updateProgressBar(state: .error, progress: 100)
        case .done, .idle:
            updateProgressBar(state: .none, progress: nil)
        }
    }

    func applyOsc9ProgressIfAllowed(state: UInt8, value: UInt8?) {
        guard !core.programStatusSnapshot().osc7501Active else { return }
        switch state {
        case 1:
            updateProgressBar(state: .normal, progress: value.map(Int.init))
        case 2:
            updateProgressBar(state: .error, progress: value.map(Int.init))
        case 3:
            updateProgressBar(state: .indeterminate, progress: value.map(Int.init))
        case 4:
            updateProgressBar(state: .paused, progress: value.map(Int.init))
        default:
            updateProgressBar(state: .none, progress: nil)
        }
    }

    func deliverFeedReplies(
        _ outcome: FfiFeedOutcome,
        legacySink: ((Data) -> Void)? = nil
    ) {
        let batch = TerminalClassifiedReplyBatch(
            replies: outcome.replies.map(TerminalClassifiedReply.init(ffi:)),
            overflowDroppedCount: outcome.replyOverflowCount
        )
        if let classified = onClassifiedReplies {
            if !batch.isEmpty {
                classified(batch)
            }
            return
        }
        if batch.hasOverflowLoss {
            delegate?.terminalView(self, didDropOverflowedReplies: batch.overflowDroppedCount)
        }
        if !outcome.output.isEmpty {
            if let legacySink {
                legacySink(outcome.output)
            } else {
                delegate?.terminalView(self, sendDeviceReplyData: outcome.output)
            }
        }
    }

    func deliverQueuedReplies() {
        let drained = core.drainClassifiedReplies(maxReplies: UInt32.max)
        let batch = TerminalClassifiedReplyBatch(
            replies: drained.replies.map(TerminalClassifiedReply.init(ffi:)),
            overflowDroppedCount: drained.overflowDroppedCount
        )
        if let classified = onClassifiedReplies {
            if !batch.isEmpty {
                classified(batch)
            }
            return
        }
        if batch.hasOverflowLoss {
            delegate?.terminalView(self, didDropOverflowedReplies: batch.overflowDroppedCount)
        }
        let flat = batch.combinedData
        if !flat.isEmpty {
            delegate?.terminalView(self, sendDeviceReplyData: flat)
        }
    }
}
#endif
