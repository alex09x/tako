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

extension TerminalParserCoordinator {
    /// Runs on `parserQueue`, and only there. Drains the pending queue one
    /// bounded batch -- or one barrier -- at a time until it is empty.
    func runParsePass() {
        while true {
            lock.lock()
            if isShutDown {
                parsePassActive = false
                lock.unlock()
                return
            }
            guard let work = takeNextWorkLocked() else {
                parsePassActive = false
                lock.unlock()
                return
            }
            if case .bytes(let batch) = work {
                batchesParsed += 1
                largestBatch = max(largestBatch, batch.count)
                if Thread.isMainThread { batchesParsedOnMainThread += 1 }
            }
            lock.unlock()

            switch work {
            case .bytes(let batch):
                TakoLog.feed.debug("batch \(batch.count)B thread=\(Thread.isMainThread ? "main" : "parser")")
                let outcome = core.feedWithOutcome(bytes: batch)
                if !outcome.output.isEmpty {
                    TakoLog.feed.debug("device reply \(outcome.output.count)B")
                }
                lock.lock()
                pendingApplications.append(.outcome(outcome))
                lock.unlock()
            case .importCheckpoint(let request):
                performImport(request)
            case .resize(let request):
                performResize(request)
            }

            lock.lock()
            let schedule = !isShutDown && claimMainApplicationLocked()
            lock.unlock()

            if schedule {
                mainDispatch { [self] in applyPendingOutcomes(holdingToken: true) }
            }
        }
    }

    /// The barrier itself, on the parser queue: no batch can be running beside
    /// it, because this is the same serial queue every batch runs on.
    private func performImport(_ request: ImportRequest) {
        do {
            let info = try core.checkpointInspect(blob: request.blob)
            try core.checkpointImport(blob: request.blob)
            let restore = TerminalCheckpointRestore(
                version: info.version,
                cols: Int(info.cols),
                rows: Int(info.rows),
                payloadLength: Int(info.payloadLen),
                epoch: core.stateEpoch()
            )

            lock.lock()
            let before = pendingApplications.count
            pendingApplications.removeAll { item in
                if case .outcome(let outcome) = item { return outcome.epoch != restore.epoch }
                return false
            }
            outcomesSuppressed += before - pendingApplications.count
            pendingApplications.append(.restored(restore, request))
            checkpointImports += 1
            lock.unlock()

            TakoLog.feed.info("checkpoint restored \(restore.cols)x\(restore.rows) epoch=\(restore.epoch)")
            request.complete(.success(restore))
        } catch {
            lock.lock()
            checkpointImportFailures += 1
            pendingApplications.append(.rejectedImport(request))
            lock.unlock()
            request.complete(.failure(error))
        }
    }

    /// The resize itself, on the parser queue: no batch can be running beside
    /// it, because this is the same serial queue every batch runs on.
    private func performResize(_ request: ResizeRequest) {
        core.resize(cols: UInt32(request.cols), rows: UInt32(request.rows))
        let applied = (cols: Int(core.cols()), rows: Int(core.rows()))
        lock.lock()
        pendingApplications.append(.resized(cols: applied.cols, rows: applied.rows, request: request))
        resizesApplied += 1
        lock.unlock()

        request.complete()
    }

    /// Cut the head of the pending queue at the batch bound, or hand back the
    /// barrier sitting at its front. Never returns an empty batch while work
    /// remains, so a pass always makes progress.
    private func takeNextWorkLocked() -> PendingWork? {
        while let head = pendingWork.first {
            switch head {
            case .importCheckpoint, .resize:
                pendingWork.removeFirst()
                return head
            case .bytes(let buffer):
                guard !buffer.isEmpty else {
                    pendingWork.removeFirst()
                    continue
                }
                let length = Self.batchLength(for: buffer)
                if length >= buffer.count {
                    pendingWork.removeFirst()
                    return .bytes(buffer)
                }
                pendingWork[0] = .bytes(Data(buffer.dropFirst(length)))
                return .bytes(Data(buffer.prefix(length)))
            }
        }
        return nil
    }

    /// How many leading bytes of `buffer` form the next batch: everything,
    /// when it fits, and otherwise `limit` bytes backed off to the start of
    /// whatever UTF-8 sequence the bound landed inside, so a batch boundary
    /// never cuts a code point in half.
    static func batchLength(for buffer: Data, limit: Int = maxBatchBytes) -> Int {
        guard buffer.count > limit else { return buffer.count }
        let base = buffer.startIndex
        func isContinuation(_ offset: Int) -> Bool {
            buffer[base + offset] & 0xC0 == 0x80
        }
        var end = limit
        var stepsBack = 0
        while end > 0, stepsBack < 4, isContinuation(end) {
            end -= 1
            stepsBack += 1
        }
        guard end > 0, !isContinuation(end) else { return limit }
        return end
    }
}
