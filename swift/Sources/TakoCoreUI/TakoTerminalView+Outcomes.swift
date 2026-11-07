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
import OSLog

#if canImport(UIKit)
import UIKit

extension TakoTerminalView {
    /// Controls whether `OSC 7501 ; ? ST` queues a capability reply on this view's engine.
    public var programStatusProbeReplyEnabled: Bool {
        get { core.isProgramStatusProbeReplyEnabled() }
        set { core.setProgramStatusProbeReplyEnabled(enabled: newValue) }
    }

    /// Current `OSC 7501` status table snapshot.
    public func programStatusSnapshot() -> TerminalProgramStatusSnapshot {
        TerminalProgramStatusSnapshot(ffi: core.programStatusSnapshot())
    }

    public func notifyProgramStatusProcessExited() {
        parserCoordinator.applyProgramStatusLifecycleBarrier(.processExited)
    }

    public func notifyProgramStatusInterrupted() {
        parserCoordinator.applyProgramStatusLifecycleBarrier(.interrupted)
    }

    public func notifyProgramStatusAcknowledged() {
        parserCoordinator.applyProgramStatusLifecycleBarrier(.acknowledged)
    }

    func applyCoordinatorProgramStatus(_ event: TerminalProgramStatusEvent) {
        delegate?.terminalView(self, didUpdateProgramStatus: event)
    }

    private func deliverFeedReplies(_ outcome: FfiFeedOutcome) {
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
            delegate?.terminalView(self, sendDeviceReplyData: outcome.output)
        }
    }

    func applyCheckpointRestore(
        _ restore: TerminalCheckpointRestore,
        restoredStatus: TerminalProgramStatusSnapshot
    ) {
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        pendingGridSize = nil

        cancelKineticScroll()

        cols = restore.cols
        rows = restore.rows
        lastReportedScrollPosition = core.scrollPosition()
        TakoLog.resize.info("checkpoint restored \(restore.cols)×\(restore.rows)")
        delegate?.terminalView(self, didRestoreCheckpoint: restore)
        delegate?.terminalView(self, didUpdateProgramStatus: .restored(restoredStatus))
        delegate?.terminalViewDidChangeContent(self)
        setNeedsDisplay()
    }

    func sendQueuedReplies() {
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
        let queued = batch.combinedData
        if !queued.isEmpty {
            delegate?.terminalView(self, sendDeviceReplyData: queued)
        }
    }

    func apply(_ outcomes: [FfiFeedOutcome]) {
        var totalDamage = false
        for outcome in outcomes {
            deliverFeedReplies(outcome)

            for event in outcome.events {
                switch event {
                case .titleChanged(let title):
                    TakoLog.feed.info("title → \"\(title)\"")
                    delegate?.terminalView(self, didChangeTitle: title)
                case .bell:
                    TakoLog.feed.debug("bell")
                    delegate?.terminalViewDidBell(self)
                case .commandStart:
                    delegate?.terminalViewCommandDidStart(self)
                case .commandEnd(let exitCode):
                    delegate?.terminalView(self, commandDidEnd: exitCode)
                case .clipboardSet(let text):
                    TakoLog.feed.info("OSC 52 → clipboard (\(text.count) chars)")
                    delegate?.terminalView(self, didRequestClipboardCopy: text)
                case .pwdChanged(let url):
                    delegate?.terminalView(self, didChangeWorkingDirectory: url)
                case .promptMark:
                    delegate?.terminalViewPromptMark(self)
                case let .statusSet(status, text):
                    delegate?.terminalView(self, didReportStatus: status, text: text)
                case .statusClear:
                    delegate?.terminalViewDidClearStatus(self)
                case let .programStatusChanged(ffiUpdate, ffiSnapshot):
                    let snapshot = TerminalProgramStatusSnapshot(ffi: ffiSnapshot)
                    delegate?.terminalView(
                        self,
                        didUpdateProgramStatus: .updated(TerminalProgramStatusUpdate(ffi: ffiUpdate), snapshot: snapshot)
                    )
                default:
                    break
                }
            }
            if outcome.statusOverflowCoalesced, let ffiResync = outcome.statusResyncSnapshot {
                let snapshot = TerminalProgramStatusSnapshot(ffi: ffiResync)
                delegate?.terminalView(
                    self,
                    didUpdateProgramStatus: .overflowCoalesced(
                        fromRevision: outcome.statusOverflowFromRevision,
                        snapshot: snapshot
                    )
                )
            }

            if outcome.hasDamage && !outcome.synchronizedOutputActive {
                totalDamage = true
                setNeedsDisplay()
            }
        }
        if isKineticScrolling, let initialModes = kineticInitialModes {
            let currentModes = core.modes()
            if currentModes.alternateScreen != initialModes.alternateScreen
                || currentModes.mouseTracking != initialModes.mouseTracking
                || currentModes.alternateScroll != initialModes.alternateScroll
                || currentModes.cursorKeyAppMode != initialModes.cursorKeyAppMode
                || core.isSynchronizedOutputActive() {
                cancelKineticScroll()
            }
        }
        if redrawHeldBySynchronizedOutput && !core.isSynchronizedOutputActive() {
            redrawHeldBySynchronizedOutput = false
            setNeedsDisplay()
        }
        if totalDamage {
            TakoLog.render.debug("damage → setNeedsDisplay (\(outcomes.count) outcomes)")
            delegate?.terminalViewDidChangeContent(self)
            notifyScrollPositionIfChanged()
        }
    }

    func notifyScrollPositionIfChanged() {
        let position = core.scrollPosition()
        guard abs(position - lastReportedScrollPosition) > 0.0001 else { return }
        lastReportedScrollPosition = position
        delegate?.terminalView(self, didScrollTo: position)
    }
}
#endif
