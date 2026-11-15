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

/// Headless, UI-free terminal session over `TakoCore` and `TerminalParserCoordinator`.
///
/// Designed for Swift daemons, session multiplexers, and tests that parse PTY
/// streams, route classified replies, and observe `OSC 7501` program status
/// without creating an `NSView`, `UIView`, `NSWindow`, or Metal renderer.
public final class TerminalHeadlessSession: @unchecked Sendable {
    public let core: TakoCore
    let parserCoordinator: TerminalParserCoordinator

    private let deliveryQueue: DispatchQueue
    private let callbackLock = NSLock()
    private var isShutDownState = false

    private var classifiedRepliesHandler: ((TerminalClassifiedReplyBatch) -> Void)?
    private var legacyReplyDataHandler: ((Data) -> Void)?
    private var replyOverflowHandler: ((UInt32) -> Void)?
    private var programStatusHandler: ((TerminalProgramStatusEvent) -> Void)?
    private var checkpointRestoredHandler: ((TerminalCheckpointRestore) -> Void)?
    private var resizedHandler: ((Int, Int) -> Void)?

    public init(
        cols: Int = 80,
        rows: Int = 24,
        scrollbackLimit: Int = 10_000,
        probeReplyEnabled: Bool = true,
        deliveryDispatch: ((@escaping () -> Void) -> Void)? = nil
    ) {
        let core = TakoCore(
            cols: UInt32(clamping: max(cols, 1)),
            rows: UInt32(clamping: max(rows, 1))
        )
        core.setScrollbackLimit(lines: UInt32(clamping: max(scrollbackLimit, 0)))
        core.setProgramStatusProbeReplyEnabled(enabled: probeReplyEnabled)
        let queue = DispatchQueue(
            label: "org.tako.terminal.headless.delivery.\(UUID().uuidString)",
            qos: .userInitiated
        )
        self.core = core
        self.deliveryQueue = queue
        let dispatch = deliveryDispatch ?? { work in queue.async(execute: work) }
        self.parserCoordinator = TerminalParserCoordinator(
            core: core,
            serializeConcurrentApplication: true,
            mainDispatch: dispatch
        )

        parserCoordinator.setMainApplicationHandler { [weak self] outcomes in
            self?.apply(outcomes)
        }
        parserCoordinator.setCheckpointRestoreWithStatusHandler { [weak self] restore, restoredStatus in
            self?.applyCheckpointRestore(restore, restoredStatus: restoredStatus)
        }
        parserCoordinator.setProgramStatusHandler { [weak self] event in
            self?.applyProgramStatus(event)
        }
        parserCoordinator.setResizeHandler { [weak self] newCols, newRows in
            self?.applyResize(cols: newCols, rows: newRows)
        }
    }

    deinit {
        parserCoordinator.shutDown()
    }

    // MARK: - Configuration & Handlers

    /// Controls whether `OSC 7501 ; ? ST` queues a capability reply.
    ///
    /// Set to `false` on passive/follower clients so only the PTY owner writes
    /// capability replies while `DA1`/`DSR`/`CPR` and status tracking stay intact.
    public var programStatusProbeReplyEnabled: Bool {
        get { core.isProgramStatusProbeReplyEnabled() }
        set { core.setProgramStatusProbeReplyEnabled(enabled: newValue) }
    }

    /// Preferred typed consume-once reply handler.
    ///
    /// When installed, replies are delivered exclusively here (never duplicated
    /// to `onDeviceReplyData` even if both closures are set).
    public var onClassifiedReplies: ((TerminalClassifiedReplyBatch) -> Void)? {
        get { callbackLock.withLock { classifiedRepliesHandler } }
        set { callbackLock.withLock { classifiedRepliesHandler = newValue } }
    }

    /// Legacy flat reply handler used only when `onClassifiedReplies` is `nil`.
    public var onDeviceReplyData: ((Data) -> Void)? {
        get { callbackLock.withLock { legacyReplyDataHandler } }
        set { callbackLock.withLock { legacyReplyDataHandler = newValue } }
    }

    /// Overflow loss notification invoked before `onDeviceReplyData` when
    /// `onClassifiedReplies` is `nil` and the bounded reply queue overflowed.
    public var onReplyOverflow: ((UInt32) -> Void)? {
        get { callbackLock.withLock { replyOverflowHandler } }
        set { callbackLock.withLock { replyOverflowHandler = newValue } }
    }

    /// Ordered `OSC 7501` status updates, burst resyncs, and checkpoint restores.
    public var onProgramStatusEvent: ((TerminalProgramStatusEvent) -> Void)? {
        get { callbackLock.withLock { programStatusHandler } }
        set { callbackLock.withLock { programStatusHandler = newValue } }
    }

    /// Ordered checkpoint restore notification.
    public var onCheckpointRestored: ((TerminalCheckpointRestore) -> Void)? {
        get { callbackLock.withLock { checkpointRestoredHandler } }
        set { callbackLock.withLock { checkpointRestoredHandler = newValue } }
    }

    /// Ordered resize notification.
    public var onResized: ((Int, Int) -> Void)? {
        get { callbackLock.withLock { resizedHandler } }
        set { callbackLock.withLock { resizedHandler = newValue } }
    }

    // MARK: - Stream & Lifecycle Operations

    public func enqueue(_ data: Data) {
        parserCoordinator.enqueue(data)
    }

    /// Feed raw PTY bytes synchronously on `parserQueue`.
    ///
    /// If invoked re-entrantly from an active session callback, parsing completes
    /// before returning while callback delivery is deferred behind the in-flight batch.
    public func feedSynchronously(_ data: Data) {
        parserCoordinator.feedSynchronously(data)
    }

    public func resize(cols: Int, rows: Int) {
        parserCoordinator.resize(cols: cols, rows: rows)
    }

    /// Replace session state from a checkpoint in stream order.
    ///
    /// Retires the previous `stateEpoch()` immediately so any remaining events
    /// from the retired epoch in an in-flight batch are suppressed.
    @discardableResult
    public func importCheckpoint(_ blob: Data) throws -> TerminalCheckpointRestore {
        try parserCoordinator.importCheckpoint(blob)
    }

    public func exportCheckpoint(maxBytes: UInt64 = 64 * 1024 * 1024) throws -> Data {
        try core.checkpointExport(flags: 0, maxBytes: maxBytes)
    }

    public func programStatusSnapshot() -> TerminalProgramStatusSnapshot {
        TerminalProgramStatusSnapshot(ffi: core.programStatusSnapshot())
    }

    public func notifyProcessExited() {
        parserCoordinator.enqueueProgramStatusLifecycle(.processExited)
    }

    public func notifyUserInterrupted() {
        parserCoordinator.enqueueProgramStatusLifecycle(.interrupted)
    }

    public func notifyUserAcknowledged() {
        parserCoordinator.enqueueProgramStatusLifecycle(.acknowledged)
    }

    public func shutDown() {
        callbackLock.lock()
        isShutDownState = true
        classifiedRepliesHandler = nil
        legacyReplyDataHandler = nil
        replyOverflowHandler = nil
        programStatusHandler = nil
        checkpointRestoredHandler = nil
        resizedHandler = nil
        callbackLock.unlock()
        parserCoordinator.shutDown()
    }

    // MARK: - Internal Delivery (Outside Locks)

    /// Callbacks are captured once per delivery and run outside the lock, so
    /// one of them may shut the session down. Each later callback in the same
    /// delivery asks this first: nothing is delivered after `shutDown()`.
    private var isDelivering: Bool {
        callbackLock.withLock { !isShutDownState }
    }

    private func applyProgramStatus(_ event: TerminalProgramStatusEvent) {
        let handler = callbackLock.withLock { () -> ((TerminalProgramStatusEvent) -> Void)? in
            guard !isShutDownState else { return nil }
            return programStatusHandler
        }
        handler?(event)
    }

    private func apply(_ outcomes: [FfiFeedOutcome]) {
        for outcome in outcomes {
            guard outcome.epoch == core.stateEpoch() else {
                parserCoordinator.reclassifyMidRunSuppressedOutcome()
                continue
            }
            let handlers = callbackLock.withLock { () -> (
                classified: ((TerminalClassifiedReplyBatch) -> Void)?,
                legacy: ((Data) -> Void)?,
                overflow: ((UInt32) -> Void)?,
                status: ((TerminalProgramStatusEvent) -> Void)?
            )? in
                guard !isShutDownState else { return nil }
                return (
                    classifiedRepliesHandler,
                    legacyReplyDataHandler,
                    replyOverflowHandler,
                    programStatusHandler
                )
            }
            guard let handlers else { return }

            let batch = TerminalClassifiedReplyBatch(
                replies: outcome.replies.map(TerminalClassifiedReply.init(ffi:)),
                overflowDroppedCount: outcome.replyOverflowCount
            )
            if let classified = handlers.classified {
                if !batch.isEmpty {
                    classified(batch)
                }
            } else {
                if batch.hasOverflowLoss {
                    handlers.overflow?(batch.overflowDroppedCount)
                }
                if !outcome.output.isEmpty, isDelivering {
                    handlers.legacy?(outcome.output)
                }
            }

            if let statusHandler = handlers.status {
                for event in outcome.events {
                    guard isDelivering else { return }
                    guard outcome.epoch == core.stateEpoch() else { break }
                    if case .programStatusChanged(let ffiUpdate, let ffiSnapshot) = event {
                        statusHandler(
                            .updated(
                                TerminalProgramStatusUpdate(ffi: ffiUpdate),
                                snapshot: TerminalProgramStatusSnapshot(ffi: ffiSnapshot)
                            )
                        )
                    }
                }
                guard isDelivering else { return }
                if outcome.epoch == core.stateEpoch(),
                   outcome.statusOverflowCoalesced,
                   let ffiResync = outcome.statusResyncSnapshot {
                    statusHandler(
                        .overflowCoalesced(
                            fromRevision: outcome.statusOverflowFromRevision,
                            snapshot: TerminalProgramStatusSnapshot(ffi: ffiResync)
                        )
                    )
                }
            }
        }
    }

    private func applyCheckpointRestore(
        _ restore: TerminalCheckpointRestore,
        restoredStatus: TerminalProgramStatusSnapshot
    ) {
        let handlers = callbackLock.withLock { () -> (
            restore: ((TerminalCheckpointRestore) -> Void)?,
            status: ((TerminalProgramStatusEvent) -> Void)?
        )? in
            guard !isShutDownState else { return nil }
            return (checkpointRestoredHandler, programStatusHandler)
        }
        guard let handlers else { return }
        handlers.restore?(restore)
        guard isDelivering else { return }
        handlers.status?(.restored(restoredStatus))
    }

    private func applyResize(cols: Int, rows: Int) {
        let handler = callbackLock.withLock { () -> ((Int, Int) -> Void)? in
            guard !isShutDownState else { return nil }
            return resizedHandler
        }
        handler?(cols, rows)
    }
}
