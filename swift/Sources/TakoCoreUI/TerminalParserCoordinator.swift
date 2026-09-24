import Foundation
import OSLog

/// One dedicated serial parser per terminal surface.
///
/// Two rules, and everything here exists to keep them: the engine is driven
/// off Main, and every consequence of driving it -- device replies, host
/// events, redraw scheduling, any UI state at all -- is applied on Main
/// in exactly the order the batches were parsed.
///
/// Between the two sits one pending-input buffer and one pending-outcome
/// queue, both FIFO, so bytes are never dropped, reordered or fed twice.
/// A burst larger than `maxBatchBytes` becomes several batches rather than
/// one unbounded call, cut only where a cut cannot split a UTF-8 sequence.
/// A main application is a single token: however many batches complete while
/// Main is busy, one application is outstanding and it drains all of them.
///
/// The coordinator holds the engine, not the view, and the parser queue
/// holds the coordinator -- so a view released with work in flight tears
/// down cleanly: `shutDown()` stops anything further reaching Main, and the
/// batch already running finishes against an engine that is still alive.
final class TerminalParserCoordinator: @unchecked Sendable {
    /// The most bytes handed to one `feedWithOutcome` call. A producer that
    /// outruns the parser coalesces into the next batch rather than into one
    /// ever-growing call, so no single parse can hold the queue -- and with
    /// it every later batch's redraw -- for an unbounded stretch. Matches
    /// `PTYDeliveryPump`'s own read-ahead bound.
    static let maxBatchBytes = 4 * 1024 * 1024

    private let core: TakoCore
    /// Serial, and this coordinator's alone: batch order is queue order.
    private let parserQueue: DispatchQueue
    /// How an application reaches Main. Injectable so the ordering and
    /// one-outstanding-application invariants are observable in a test
    /// without a run loop.
    private let mainDispatch: (@escaping () -> Void) -> Void

    private let lock = NSLock()

    /// One FIFO for everything the engine is driven by, bytes and barriers
    /// alike.
    ///
    /// A checkpoint import is not a side door: it takes its place in this
    /// queue and the parse pass reaches it in order. Appending an import block
    /// to `parserQueue` instead would let `runParsePass` -- which loops until
    /// the shared pending buffer empties -- starve it indefinitely, and would
    /// let bytes that arrived *after* the checkpoint be consumed before it.
    private enum PendingWork {
        case bytes(Data)
        case importCheckpoint(ImportRequest)
        case resize(ResizeRequest)
    }

    /// A barrier's caller needs two different answers, and they arrive at
    /// different times: "the engine has done it" (which releases the caller
    /// from its wait) and "Main has been told about it" (which is where the
    /// caller's synchronous obligation ends). This is the second one.
    ///
    /// Without it a barrier's synchronous publication has no boundary: the
    /// drain loop keeps taking whatever the parser has produced *since*, and a
    /// producer that never stops keeps the caller on Main forever even though
    /// its own barrier was applied in the first pass.
    protocol BarrierPublication: AnyObject {
        var isPublished: Bool { get }
        func markPublished()
    }

    /// A pending ordered import: the blob to apply and the caller waiting on
    /// the barrier.
    final class ImportRequest: BarrierPublication, @unchecked Sendable {
        let blob: Data
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var outcome: Result<TerminalCheckpointRestore, Error>?
        private var published = false

        init(blob: Data) {
            self.blob = blob
        }

        var isPublished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return published
        }

        /// Called on Main, the instant this import's restore has been handed
        /// to the host's handler.
        func markPublished() {
            lock.lock()
            published = true
            lock.unlock()
        }

        /// First completion wins, so a shutdown racing the barrier cannot
        /// double-signal or overwrite a real result.
        func complete(_ result: Result<TerminalCheckpointRestore, Error>) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = result
            lock.unlock()
            done.signal()
        }

        func wait() throws -> TerminalCheckpointRestore {
            done.wait()
            lock.lock()
            let result = outcome
            lock.unlock()
            switch result {
            case .success(let restore): return restore
            case .failure(let error): throw error
            case nil: throw TerminalCheckpointImportError.shutDown
            }
        }
    }

    /// A pending ordered resize: the geometry to adopt and the caller waiting
    /// on the barrier.
    ///
    /// A resize needs its own completion for the same reason an import does.
    /// Waiting on "the parse pass returned" instead answers a different
    /// question: the pass drains the *whole* queue, so bytes that arrived
    /// after the resize held the caller for as long as they took to parse.
    /// This completes at the barrier itself, which is the event the caller
    /// actually needs.
    final class ResizeRequest: BarrierPublication, @unchecked Sendable {
        let cols: Int
        let rows: Int
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var completed = false
        private var published = false

        init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }

        var isPublished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return published
        }

        /// Called on Main, the instant this resize has been handed to the
        /// host's handler.
        func markPublished() {
            lock.lock()
            published = true
            lock.unlock()
        }

        /// First completion wins, so a shutdown racing the barrier cannot
        /// double-signal.
        func complete() {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()
            done.signal()
        }

        func wait() { done.wait() }
    }

    /// What Main is owed, in the order the parser produced it. A restore is a
    /// member of this stream rather than a separate hop, so a host cannot see
    /// an outcome and its own replacement out of order.
    private enum PendingApplication {
        case outcome(FfiFeedOutcome)
        case restored(TerminalCheckpointRestore, ImportRequest)
        /// An import the engine refused. It publishes nothing -- there is no
        /// new state to hand anyone -- but it still occupies its place in the
        /// order, which is what lets its caller stop there.
        case rejectedImport(ImportRequest)
        case resized(cols: Int, rows: Int, request: ResizeRequest)
    }

    // Everything below is guarded by `lock`.

    private var pendingWork: [PendingWork] = []
    private var pendingApplications: [PendingApplication] = []
    /// A parse pass is queued or running. The pass drains whatever arrives
    /// while it runs, so a burst of feeds costs one pass, not one per feed.
    private var parsePassActive = false
    /// The single main-application token: held from the moment an
    /// application is scheduled (or begun inline) until it finds nothing
    /// left to apply.
    private var mainApplicationActive = false
    private var isShutDown = false
    private var applyOnMain: (([FfiFeedOutcome]) -> Void)?
    private var onCheckpointRestored: ((TerminalCheckpointRestore) -> Void)?
    private var onResized: ((Int, Int) -> Void)?

    // Counters, for tests and for a host that wants to log them.
    private var batchesParsed = 0
    private var batchesParsedOnMainThread = 0
    private var largestBatch = 0
    private var outstandingMainApplications = 0
    private var peakMainApplications = 0
    private var outcomesApplied = 0
    private var checkpointImports = 0
    private var checkpointImportFailures = 0
    private var outcomesSuppressed = 0
    private var resizesApplied = 0

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

    /// Install the handler an ordered resize is reported through, once the
    /// engine has actually been resized. Called on Main; invoked only on Main,
    /// in stream order. The geometry it carries is read back from the engine,
    /// not echoed from the request.
    func setResizeHandler(_ handler: @escaping (Int, Int) -> Void) {
        lock.lock()
        onResized = handler
        lock.unlock()
    }

    // MARK: Feeding

    /// Append bytes and return immediately. Nothing blocks: not the caller,
    /// not Main, not the parser.
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

    /// Bytes coalesce into the tail of the queue, but never across a barrier:
    /// input that arrived after a checkpoint stays behind it.
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
    ///
    /// Must be called from Main: the inline application is what preserves
    /// `feed(data:)`'s synchronous contract. The engine still runs on the
    /// parser queue -- Main waits for it rather than doing it -- so the
    /// "never parse on Main" rule holds even here.
    func feedSynchronously(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !isShutDown else { lock.unlock(); return }
        appendBytesLocked(data)
        let startPass = !parsePassActive
        if startPass { parsePassActive = true }
        // Take the token up front so the pass cannot also schedule an
        // application onto a Main that is about to apply inline anyway.
        let holdsToken = claimMainApplicationLocked()
        lock.unlock()

        let parsed = DispatchSemaphore(value: 0)
        parserQueue.async { [self] in
            // When a pass was already active it is ahead of this block on
            // the same serial queue, and it drains the bytes just appended;
            // this block only has to observe that it finished.
            if startPass { runParsePass() }
            parsed.signal()
        }
        parsed.wait()

        // If the token was already held, an application is sitting on the
        // main queue behind this very call and cannot run until it returns.
        // Applying its work here early is not a second application: the
        // outcome queue is drained in order either way, and the scheduled
        // block finds nothing left and releases the token.
        applyPendingOutcomes(holdingToken: holdsToken)
    }

    // MARK: Checkpoint barrier

    /// Replace the engine's whole state from a checkpoint, in order.
    ///
    /// The import is a barrier in the parser's own FIFO: everything fed before
    /// it has been parsed when it runs, and nothing fed after it has. That is
    /// the corruption this exists to eliminate -- an import called on Main
    /// races a parser queue that is still consuming PTY bytes into the state
    /// it is about to replace.
    ///
    /// Pre-barrier bytes already accepted are parsed first, in FIFO order,
    /// rather than being rolled back: their outcomes are dropped at
    /// application time by the epoch they carry, which needs no rollback
    /// machinery to be correct.
    ///
    /// Must be called from Main, like `feedSynchronously`: the restore is
    /// applied inline before this returns, so a caller that reads the view
    /// straight after sees the restored terminal. Throws the engine's own
    /// typed error (unsupported version, corrupt, too large) unchanged.
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
        // Same reasoning as `feedSynchronously`: hold the token so the pass
        // cannot schedule an application onto a Main that is about to apply
        // inline anyway.
        let holdsToken = claimMainApplicationLocked()
        lock.unlock()

        if startPass {
            parserQueue.async { [self] in runParsePass() }
        }

        defer { applyPendingOutcomes(holdingToken: holdsToken, upTo: request) }
        return try request.wait()
    }

    // MARK: Resize barrier

    /// Resize the engine's grid, in order against the byte stream.
    ///
    /// A resize is a reflow: it rewraps the grid and moves the cursor, so
    /// whether a given byte was printed before or after it changes what the
    /// screen says. Calling `core.resize` from Main while the parser queue is
    /// still consuming PTY bytes decides that by a race -- which is the same
    /// class of corruption the checkpoint barrier exists to remove, and it is
    /// fixed the same way: the resize takes its place in the one FIFO, so
    /// every byte accepted before it is parsed at the old geometry and every
    /// byte accepted after it at the new one.
    ///
    /// This blocks Main until the barrier has been applied, the same shape as
    /// ``feedSynchronously(_:)`` and for the same reason: a host resizes its
    /// grid and then immediately lays out, draws and tells its own delegate
    /// about the new geometry, so handing it back a size the engine has not
    /// adopted yet would only move the race. It is not a new cost either --
    /// calling `core.resize` straight from Main already parks on the engine
    /// mutex behind whatever batch is mid-parse.
    ///
    /// The installed resize handler fires on Main before this returns, after
    /// the outcomes of every byte parsed at the old geometry.
    ///
    /// Redundant requests are not coalesced here: the engine decides what a
    /// resize to its current size means, and the handler reports the geometry
    /// the engine actually ended up with.
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

    // MARK: Parsing

    /// Runs on `parserQueue`, and only there. Drains the pending queue one
    /// bounded batch -- or one barrier -- at a time until it is empty.
    private func runParsePass() {
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
            // Read what the container declares before committing to it, so a
            // rejected import costs nothing and the restored geometry comes
            // from the checkpoint rather than from a second, racing query.
            let info = try core.checkpointInspect(blob: request.blob)
            try core.checkpointImport(blob: request.blob)
            // The engine published the new epoch inside the same critical
            // section as the swap; this reads it back through that same lock.
            let restore = TerminalCheckpointRestore(
                version: info.version,
                cols: Int(info.cols),
                rows: Int(info.rows),
                payloadLength: Int(info.payloadLen),
                epoch: core.stateEpoch()
            )

            lock.lock()
            // Outcomes parsed before the swap describe an engine that no
            // longer exists. Dropping them here as well as at application
            // time keeps the queue from carrying work that is already dead.
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
            // Fail-intact: the engine refused the payload and is exactly what
            // it was, so nothing is applied to the host. The barrier is queued
            // anyway, because the caller is waiting to be told where in the
            // order its attempt landed. Without it the caller has a boundary
            // that is never published, and keeps draining Main for as long as
            // the parser keeps producing.
            //
            // Queued before the completion below: the caller's own drain runs
            // the moment it wakes, and must find this already in the queue.
            pendingApplications.append(.rejectedImport(request))
            lock.unlock()
            request.complete(.failure(error))
        }
    }

    /// The resize itself, on the parser queue: no batch can be running beside
    /// it, because this is the same serial queue every batch runs on.
    ///
    /// A resize does not replace the engine, so it does not move the epoch and
    /// the outcomes queued ahead of it stay valid -- unlike an import, nothing
    /// here is suppressed.
    private func performResize(_ request: ResizeRequest) {
        core.resize(cols: UInt32(request.cols), rows: UInt32(request.rows))
        // Read back rather than echo. Today this cannot differ: `Terminal::resize`
        // adopts every positive request and only refuses a zero dimension, which
        // `resize(cols:rows:)` has already rejected. It is written this way so
        // that the number the host is told is the engine's own -- if the engine
        // ever does adjust a request, the report follows it instead of silently
        // disagreeing with the grid.
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
    ///
    /// Total: malformed input (a run of continuation bytes longer than any
    /// real sequence, or one that reaches the start of the buffer) keeps the
    /// full bound rather than shrinking the batch to nothing.
    static func batchLength(for buffer: Data, limit: Int = maxBatchBytes) -> Int {
        guard buffer.count > limit else { return buffer.count }
        let base = buffer.startIndex
        func isContinuation(_ offset: Int) -> Bool {
            buffer[base + offset] & 0xC0 == 0x80
        }
        var end = limit
        // A code point is at most four bytes, so at most three continuation
        // bytes precede its lead byte -- one step more than that means the
        // bytes are not a code point at all.
        var stepsBack = 0
        while end > 0, stepsBack < 4, isContinuation(end) {
            end -= 1
            stepsBack += 1
        }
        guard end > 0, !isContinuation(end) else { return limit }
        return end
    }

    // MARK: Applying

    /// Drain every parsed outcome, in order, through the installed handler.
    /// Runs on Main -- either dispatched there or inline on a
    /// `feedSynchronously` caller.
    private func applyPendingOutcomes(
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
            // A bounded caller stops the moment its own barrier has reached
            // the host. Anything the parser has produced since is somebody
            // else's turn -- scheduled below, never abandoned.
            if let boundary, boundary.isPublished {
                let schedule = handOffRemainderLocked(holdingToken: holdingToken)
                lock.unlock()
                if schedule {
                    mainDispatch { [self] in applyPendingOutcomes(holdingToken: true) }
                }
                return
            }
            if isShutDown || pendingApplications.isEmpty {
                // Release only once nothing new has arrived; a batch that
                // lands after this point sees a free token and schedules its
                // own application, so none is ever left unapplied.
                if holdingToken { releaseMainApplicationLocked() }
                lock.unlock()
                return
            }
            let batch = pendingApplications
            pendingApplications.removeAll(keepingCapacity: true)
            lock.unlock()

            // The engine's own generation, read from the engine under its own
            // lock. An outcome captured before a swap can reach here after it,
            // and a coordinator-level epoch would be invisible to the
            // observers -- render frames, scroll position, buffer text -- that
            // reach the core directly.
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
                    // Everything parsed before the swap is applied first, then
                    // the replacement: a host never sees them out of order.
                    flushRun()
                    request.markPublished()
                    restoreHandler?(restore)
                case .rejectedImport(let request):
                    // Everything parsed before the attempt is applied first,
                    // exactly as for a restore, so the caller's barrier means
                    // the same thing whether the engine took the payload or
                    // refused it. Nothing follows: no restore, no epoch move,
                    // no view change -- the engine never changed.
                    flushRun()
                    request.markPublished()
                case .resized(let cols, let rows, let request):
                    // Same rule as a restore: the outcomes of the bytes parsed
                    // at the old geometry are applied before the host is told
                    // the geometry changed.
                    flushRun()
                    request.markPublished()
                    resizeHandler?(cols, rows)
                }

                guard let boundary, boundary.isPublished else { continue }
                // This caller's barrier has just reached the host. Put back
                // what is left of this batch -- ahead of anything that arrived
                // while we were applying, so FIFO survives -- and hand the
                // rest off rather than carrying it.
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
    ///
    /// Returns `true` when the caller must schedule an asynchronous drain,
    /// having kept or just taken the token. Returns `false` when there is
    /// nothing left, or when somebody else already holds the token and is
    /// therefore on the hook for it.
    private func handOffRemainderLocked(holdingToken: Bool) -> Bool {
        if isShutDown || pendingApplications.isEmpty {
            if holdingToken { releaseMainApplicationLocked() }
            return false
        }
        if holdingToken { return true }
        // The holder we deferred to may have drained to empty and released
        // while this caller was blocked on its barrier. A vacant token with
        // work behind it is the one state nobody would come back for.
        return claimMainApplicationLocked()
    }

    private func claimMainApplicationLocked() -> Bool {
        guard !mainApplicationActive else { return false }
        mainApplicationActive = true
        outstandingMainApplications += 1
        peakMainApplications = max(peakMainApplications, outstandingMainApplications)
        return true
    }

    private func releaseMainApplicationLocked() {
        guard mainApplicationActive else { return }
        mainApplicationActive = false
        outstandingMainApplications -= 1
    }

    // MARK: Teardown

    /// Stop turning bytes into work for a host that is going away. Anything
    /// already inside `feedWithOutcome` finishes against the engine, which
    /// this coordinator keeps alive; nothing further reaches Main.
    func shutDown() {
        lock.lock()
        isShutDown = true
        // A barrier still waiting in the queue will never run now, and its
        // caller is blocked on it. Fail it rather than leave Main parked
        // forever; one already handed to the parser completes on its own, and
        // `ImportRequest.complete` keeps whichever result arrives first.
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
        // A resize has no result to fail, but its caller is parked on the same
        // kind of barrier and must not stay there.
        for request in abandonedResizes {
            request.complete()
        }
    }

    // MARK: Introspection

    /// Batches handed to the engine from the main thread. The whole point of
    /// this type is that it stays zero.
    var mainThreadBatchCount: Int { lock.withLock { batchesParsedOnMainThread } }
    var batchCount: Int { lock.withLock { batchesParsed } }
    var largestBatchByteCount: Int { lock.withLock { largestBatch } }
    /// The most main applications ever outstanding at once. Bounded at one.
    var peakOutstandingMainApplications: Int { lock.withLock { peakMainApplications } }
    var appliedOutcomeCount: Int { lock.withLock { outcomesApplied } }
    /// Checkpoint barriers that replaced the engine.
    var checkpointImportCount: Int { lock.withLock { checkpointImports } }
    /// Checkpoint barriers the engine refused. The engine is intact after each.
    var checkpointImportFailureCount: Int { lock.withLock { checkpointImportFailures } }
    /// Outcomes dropped because the engine they were parsed against is gone.
    var suppressedOutcomeCount: Int { lock.withLock { outcomesSuppressed } }
    /// Resize barriers the engine has actually applied.
    var appliedResizeCount: Int { lock.withLock { resizesApplied } }
    /// Work still queued behind the parser, bytes and barriers together.
    var pendingWorkCount: Int { lock.withLock { pendingWork.count } }

    /// Test seam: block until the parser queue has run everything queued on
    /// it. Waits on the parser queue only -- never on Main -- so it is safe
    /// to call from the main thread.
    func waitForParserQuiescence() {
        let idle = DispatchSemaphore(value: 0)
        parserQueue.async { idle.signal() }
        idle.wait()
    }
}
