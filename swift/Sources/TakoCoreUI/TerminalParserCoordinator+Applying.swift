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

extension TerminalParserCoordinator {
    /// Drain every parsed outcome, in order, through the installed handler.
    /// Runs on Main -- either dispatched there or inline on a
    /// `feedSynchronously` caller.
    func applyPendingOutcomes(
        holdingToken: Bool,
        upTo boundary: (any BarrierPublication)? = nil
    ) {
        guard enterApplicationGate(holdingToken: holdingToken, upTo: boundary) else {
            return
        }
        defer {
            leaveApplicationGate()
        }

        lock.lock()
        let handler = applyOnMain
        let restoreHandler = onCheckpointRestored
        let restoreWithStatusHandler = onCheckpointRestoredWithStatus
        let programStatusHandler = onProgramStatus
        let resizeHandler = onResized
        lock.unlock()

        while true {
            let stopBeforeBatch = shouldStopAtBoundary(boundary)
            let holdsEffectiveToken = holdingToken || hasDeferredReentrantHoldingToken()
            lock.lock()
            if stopBeforeBatch {
                let schedule = handOffRemainderLocked(holdingToken: holdsEffectiveToken)
                lock.unlock()
                if schedule {
                    mainDispatch { [self] in applyPendingOutcomes(holdingToken: true) }
                }
                return
            }
            if isShutDown || pendingApplications.isEmpty {
                if holdsEffectiveToken { releaseMainApplicationLocked() }
                lock.unlock()
                return
            }
            let batch = pendingApplications
            pendingApplications.removeAll(keepingCapacity: true)
            lock.unlock()

            var run: [FfiFeedOutcome] = []

            func flushRun() {
                guard !run.isEmpty else { return }
                let liveEpoch = core.stateEpoch()
                var liveRun: [FfiFeedOutcome] = []
                liveRun.reserveCapacity(run.count)
                var droppedInFlush = 0
                for item in run {
                    if item.epoch == liveEpoch {
                        liveRun.append(item)
                    } else {
                        droppedInFlush += 1
                    }
                }
                run.removeAll(keepingCapacity: true)
                lock.lock()
                outcomesApplied += liveRun.count
                outcomesSuppressed += droppedInFlush
                lock.unlock()
                if !liveRun.isEmpty {
                    handler?(liveRun)
                }
            }

            var stoppedAtBoundary = false
            for (index, item) in batch.enumerated() {
                switch item {
                case .outcome(let outcome):
                    guard outcome.epoch == core.stateEpoch() else {
                        lock.lock()
                        outcomesSuppressed += 1
                        lock.unlock()
                        continue
                    }
                    run.append(outcome)
                case .restored(let restore, let restoredStatus, let request):
                    flushRun()
                    request.markPublished()
                    if let restoreWithStatusHandler {
                        restoreWithStatusHandler(restore, restoredStatus)
                    } else {
                        restoreHandler?(restore)
                    }
                case .rejectedImport(let request):
                    flushRun()
                    request.markPublished()
                case .resized(let cols, let rows, let request):
                    flushRun()
                    request.markPublished()
                    resizeHandler?(cols, rows)
                case .programStatusLifecycle(let event, let itemEpoch, let request):
                    flushRun()
                    request.markPublished()
                    guard itemEpoch == core.stateEpoch() else {
                        lock.lock()
                        outcomesSuppressed += 1
                        lock.unlock()
                        break
                    }
                    if let event {
                        programStatusHandler?(event)
                    }
                }

                guard shouldStopAtBoundary(boundary) else { continue }
                flushRun()
                let remainder = batch[batch.index(after: index)...]
                let holdsTokenNow = holdingToken || hasDeferredReentrantHoldingToken()
                lock.lock()
                if !remainder.isEmpty {
                    pendingApplications.insert(contentsOf: remainder, at: 0)
                }
                let schedule = handOffRemainderLocked(holdingToken: holdsTokenNow)
                lock.unlock()
                if schedule {
                    mainDispatch { [self] in applyPendingOutcomes(holdingToken: true) }
                }
                stoppedAtBoundary = true
                break
            }
            if stoppedAtBoundary { return }
            flushRun()
        }
    }

    /// Decide who finishes the applications a bounded caller is leaving
    /// behind, without letting the single-application token go slack.
    func handOffRemainderLocked(holdingToken: Bool) -> Bool {
        if isShutDown || pendingApplications.isEmpty {
            if holdingToken { releaseMainApplicationLocked() }
            return false
        }
        if holdingToken { return true }
        return claimMainApplicationLocked()
    }

    func claimMainApplicationLocked() -> Bool {
        guard !mainApplicationActive else { return false }
        mainApplicationActive = true
        outstandingMainApplications += 1
        peakMainApplications = max(peakMainApplications, outstandingMainApplications)
        return true
    }

    func releaseMainApplicationLocked() {
        guard mainApplicationActive else { return }
        mainApplicationActive = false
        outstandingMainApplications -= 1
    }

    private func enterApplicationGate(
        holdingToken: Bool,
        upTo boundary: (any BarrierPublication)?
    ) -> Bool {
        let current = Thread.current
        applicationCondition.lock()
        if activeApplicationThread === current {
            if let boundary {
                deferredReentrantBoundaries.append(boundary)
            } else {
                deferredReentrantUnboundedDrain = true
            }
            if holdingToken {
                deferredReentrantHoldingToken = true
            }
            applicationCondition.unlock()
            return false
        }
        if serializeConcurrentApplication {
            while activeApplicationThread != nil {
                applicationCondition.wait()
            }
        }
        activeApplicationThread = current
        deferredReentrantUnboundedDrain = false
        deferredReentrantHoldingToken = false
        deferredReentrantBoundaries.removeAll(keepingCapacity: true)
        applicationCondition.unlock()
        return true
    }

    private func shouldStopAtBoundary(_ primary: (any BarrierPublication)?) -> Bool {
        applicationCondition.lock()
        defer { applicationCondition.unlock() }
        if deferredReentrantUnboundedDrain {
            return false
        }
        if primary == nil && deferredReentrantBoundaries.isEmpty {
            return false
        }
        let primaryDone = primary?.isPublished ?? true
        return primaryDone && deferredReentrantBoundaries.allSatisfy(\.isPublished)
    }

    private func hasDeferredReentrantHoldingToken() -> Bool {
        applicationCondition.lock()
        defer { applicationCondition.unlock() }
        return deferredReentrantHoldingToken
    }

    private func leaveApplicationGate() {
        applicationCondition.lock()
        activeApplicationThread = nil
        deferredReentrantUnboundedDrain = false
        deferredReentrantHoldingToken = false
        deferredReentrantBoundaries.removeAll(keepingCapacity: true)
        applicationCondition.broadcast()
        applicationCondition.unlock()
    }
}
