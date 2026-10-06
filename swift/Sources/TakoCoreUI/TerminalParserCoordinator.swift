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

/// One dedicated serial parser per terminal surface.
///
/// Two rules, and everything here exists to keep them: the engine is driven
/// off Main, and every consequence of driving it -- device replies, host
/// events, redraw scheduling, any UI state at all -- is applied on Main
/// in exactly the order the batches were parsed.
final class TerminalParserCoordinator: @unchecked Sendable {
    /// The most bytes handed to one `feedWithOutcome` call.
    static let maxBatchBytes = 4 * 1024 * 1024

    let core: TakoCore
    /// Serial, and this coordinator's alone: batch order is queue order.
    let parserQueue: DispatchQueue
    /// How an application reaches Main. Injectable for testing.
    let mainDispatch: (@escaping () -> Void) -> Void

    let lock = NSLock()

    var pendingWork: [PendingWork] = []
    var pendingApplications: [PendingApplication] = []
    var parsePassActive = false
    var mainApplicationActive = false
    var isShutDown = false
    var applyOnMain: (([FfiFeedOutcome]) -> Void)?
    var onCheckpointRestored: ((TerminalCheckpointRestore) -> Void)?
    var onResized: ((Int, Int) -> Void)?

    // Counters, for tests and for a host that wants to log them.
    var batchesParsed = 0
    var batchesParsedOnMainThread = 0
    var largestBatch = 0
    var outstandingMainApplications = 0
    var peakMainApplications = 0
    var outcomesApplied = 0
    var checkpointImports = 0
    var checkpointImportFailures = 0
    var outcomesSuppressed = 0
    var resizesApplied = 0

    init(
        core: TakoCore,
        mainDispatch: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.core = core
        self.parserQueue = DispatchQueue(
            label: "org.tako.terminal.parser.\(UUID().uuidString)",
            qos: .userInitiated
        )
        self.mainDispatch = mainDispatch
    }

    /// Install the one handler every batch is applied through, whoever fed
    /// it. Called on Main; invoked only on Main.
    func setMainApplicationHandler(_ handler: @escaping ([FfiFeedOutcome]) -> Void) {
        lock.lock()
        applyOnMain = handler
        lock.unlock()
    }

    /// Install the handler a completed checkpoint restore is reported through.
    /// Called on Main; invoked only on Main, in stream order.
    func setCheckpointRestoreHandler(_ handler: @escaping (TerminalCheckpointRestore) -> Void) {
        lock.lock()
        onCheckpointRestored = handler
        lock.unlock()
    }

    /// Install the handler an ordered resize is reported through.
    func setResizeHandler(_ handler: @escaping (Int, Int) -> Void) {
        lock.lock()
        onResized = handler
        lock.unlock()
    }

    // MARK: - Feeding

    /// Append bytes and return immediately.
    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !isShutDown else { lock.unlock(); return }
        appendBytesLocked(data)
        let startPass = !parsePassActive
        if startPass { parsePassActive = true }
        lock.unlock()

        guard startPass else { return }
        parserQueue.async { [self] in runParsePass() }
    }

    private func appendBytesLocked(_ data: Data) {
        if case .bytes(var tail)? = pendingWork.last {
            tail.append(data)
            pendingWork[pendingWork.count - 1] = .bytes(tail)
        } else {
            pendingWork.append(.bytes(data))
        }
    }

    /// Append bytes, wait for the parser to consume everything pending, then
    /// apply the outcomes on this thread before returning.
    func feedSynchronously(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !isShutDown else { lock.unlock(); return }
        appendBytesLocked(data)
        let startPass = !parsePassActive
        if startPass { parsePassActive = true }
        let holdsToken = claimMainApplicationLocked()
        lock.unlock()

        let parsed = DispatchSemaphore(value: 0)
        parserQueue.async { [self] in
            if startPass { runParsePass() }
            parsed.signal()
        }
        parsed.wait()

        applyPendingOutcomes(holdingToken: holdsToken)
    }

    // MARK: - Checkpoint barrier

    @discardableResult
    func importCheckpoint(_ blob: Data) throws -> TerminalCheckpointRestore {
        lock.lock()
        guard !isShutDown else {
            lock.unlock()
            throw TerminalCheckpointImportError.shutDown
        }
        let request = ImportRequest(blob: blob)
        pendingWork.append(.importCheckpoint(request))
        let startPass = !parsePassActive
        if startPass { parsePassActive = true }
        let holdsToken = claimMainApplicationLocked()
        lock.unlock()

        if startPass {
            parserQueue.async { [self] in runParsePass() }
        }

        defer { applyPendingOutcomes(holdingToken: holdsToken, upTo: request) }
        return try request.wait()
    }

    // MARK: - Resize barrier

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lock.lock()
        guard !isShutDown else { lock.unlock(); return }
        let request = ResizeRequest(cols: cols, rows: rows)
        pendingWork.append(.resize(request))
        let startPass = !parsePassActive
        if startPass { parsePassActive = true }
        let holdsToken = claimMainApplicationLocked()
        lock.unlock()

        if startPass {
            parserQueue.async { [self] in runParsePass() }
        }

        defer { applyPendingOutcomes(holdingToken: holdsToken, upTo: request) }
        request.wait()
    }

    // MARK: - Teardown

    func shutDown() {
        lock.lock()
        isShutDown = true
        let abandoned = pendingWork.compactMap { work -> ImportRequest? in
            if case .importCheckpoint(let request) = work { return request }
            return nil
        }
        let abandonedResizes = pendingWork.compactMap { work -> ResizeRequest? in
            if case .resize(let request) = work { return request }
            return nil
        }
        pendingWork.removeAll()
        pendingApplications.removeAll()
        applyOnMain = nil
        onCheckpointRestored = nil
        onResized = nil
        lock.unlock()

        for request in abandoned {
            request.complete(.failure(TerminalCheckpointImportError.shutDown))
        }
        for request in abandonedResizes {
            request.complete()
        }
    }

    // MARK: - Introspection

    var mainThreadBatchCount: Int { lock.withLock { batchesParsedOnMainThread } }
    var batchCount: Int { lock.withLock { batchesParsed } }
    var largestBatchByteCount: Int { lock.withLock { largestBatch } }
    var peakOutstandingMainApplications: Int { lock.withLock { peakMainApplications } }
    var appliedOutcomeCount: Int { lock.withLock { outcomesApplied } }
    var checkpointImportCount: Int { lock.withLock { checkpointImports } }
    var checkpointImportFailureCount: Int { lock.withLock { checkpointImportFailures } }
    var suppressedOutcomeCount: Int { lock.withLock { outcomesSuppressed } }
    var appliedResizeCount: Int { lock.withLock { resizesApplied } }
    var pendingWorkCount: Int { lock.withLock { pendingWork.count } }

    func waitForParserQuiescence() {
        let idle = DispatchSemaphore(value: 0)
        parserQueue.async { idle.signal() }
        idle.wait()
    }
}
