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
        lock.lock()
        let handler = applyOnMain
        let restoreHandler = onCheckpointRestored
        let resizeHandler = onResized
        lock.unlock()

        while true {
            lock.lock()
            if let boundary, boundary.isPublished {
                let schedule = handOffRemainderLocked(holdingToken: holdingToken)
                lock.unlock()
                if schedule {
                    mainDispatch { [self] in applyPendingOutcomes(holdingToken: true) }
                }
                return
            }
            if isShutDown || pendingApplications.isEmpty {
                if holdingToken { releaseMainApplicationLocked() }
                lock.unlock()
                return
            }
            let batch = pendingApplications
            pendingApplications.removeAll(keepingCapacity: true)
            lock.unlock()

            let epoch = core.stateEpoch()
            var run: [FfiFeedOutcome] = []

            func flushRun() {
                guard !run.isEmpty else { return }
                lock.lock()
                outcomesApplied += run.count
                lock.unlock()
                handler?(run)
                run.removeAll(keepingCapacity: true)
            }

            var stoppedAtBoundary = false
            for (index, item) in batch.enumerated() {
                switch item {
                case .outcome(let outcome):
                    guard outcome.epoch == epoch else {
                        lock.lock()
                        outcomesSuppressed += 1
                        lock.unlock()
                        continue
                    }
                    run.append(outcome)
                case .restored(let restore, let request):
                    flushRun()
                    request.markPublished()
                    restoreHandler?(restore)
                case .rejectedImport(let request):
                    flushRun()
                    request.markPublished()
                case .resized(let cols, let rows, let request):
                    flushRun()
                    request.markPublished()
                    resizeHandler?(cols, rows)
                }

                guard let boundary, boundary.isPublished else { continue }
                flushRun()
                let remainder = batch[batch.index(after: index)...]
                lock.lock()
                if !remainder.isEmpty {
                    pendingApplications.insert(contentsOf: remainder, at: 0)
                }
                let schedule = handOffRemainderLocked(holdingToken: holdingToken)
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
}
