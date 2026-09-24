import Foundation
import XCTest
@testable import TakoCoreUI

/// A stand-in for the main queue: an application lands here instead of being
/// dispatched, so a test decides exactly when it runs.
private final class CheckpointMainQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [() -> Void] = []
    private var peak = 0

    func dispatch(_ block: @escaping () -> Void) {
        lock.lock()
        blocks.append(block)
        peak = max(peak, blocks.count)
        lock.unlock()
    }

    @discardableResult
    func drain() -> Int {
        var ran = 0
        while true {
            lock.lock()
            let next = blocks.isEmpty ? nil : blocks.removeFirst()
            lock.unlock()
            guard let next else { return ran }
            next()
            ran += 1
        }
    }

    var peakDepth: Int { lock.withLock { peak } }
}

/// Records what reached Main, and in what order.
private final class CheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var applications: [[FfiFeedOutcome]] = []
    private(set) var restores: [TerminalCheckpointRestore] = []
    /// Outcomes and restores interleaved, as Main saw them.
    private(set) var stream: [String] = []

    func record(_ outcomes: [FfiFeedOutcome]) {
        lock.lock()
        applications.append(outcomes)
        stream.append("outcomes(\(outcomes.count))")
        lock.unlock()
    }

    func recordRestore(_ restore: TerminalCheckpointRestore) {
        lock.lock()
        restores.append(restore)
        stream.append("restore(\(restore.cols)x\(restore.rows))")
        lock.unlock()
    }

    var outcomes: [FfiFeedOutcome] { lock.withLock { applications.flatMap { $0 } } }
    var restoreCount: Int { lock.withLock { restores.count } }
    var events: [FfiEvent] { outcomes.flatMap { $0.events } }
    var titles: [String] {
        events.compactMap {
            if case .titleChanged(let title) = $0 { return title }
            return nil
        }
    }
}

/// Ordering, linearization and staleness for checkpoint imports driven through
/// `TerminalParserCoordinator`.
///
/// Every suite name here carries "Checkpoint" so `swift-test.sh --filter
/// Checkpoint` actually gates it.
final class TerminalCheckpointOrderingTests: XCTestCase {
    private func makeCoordinator(
        core: TakoCore,
        main: CheckpointMainQueue,
        recorder: CheckpointRecorder
    ) -> TerminalParserCoordinator {
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)
        coordinator.setMainApplicationHandler(recorder.record)
        coordinator.setCheckpointRestoreHandler(recorder.recordRestore)
        return coordinator
    }

    /// A checkpoint of a terminal that has `text` on screen, at `cols`x`rows`.
    private func checkpoint(of text: String, cols: UInt32 = 40, rows: UInt32 = 10) -> Data {
        let source = TakoCore(cols: cols, rows: rows)
        source.feed(bytes: Data(text.utf8))
        return source.checkpoint()
    }

    private func drainFully(_ coordinator: TerminalParserCoordinator, _ main: CheckpointMainQueue) {
        for _ in 0..<16 {
            coordinator.waitForParserQuiescence()
            if main.drain() == 0 { break }
        }
    }

    /// The import travels through the parser's own FIFO: bytes fed before it
    /// are parsed before the swap and bytes fed after it land on the restored
    /// engine. Neither can be consumed on the wrong side of the barrier.
    func testCheckpointImportIsOrderedAgainstTheParserQueue() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        let blob = checkpoint(of: "RESTORED")

        coordinator.enqueue(Data("BEFORE-THE-BARRIER\r\n".utf8))
        let restore = try coordinator.importCheckpoint(blob)
        coordinator.enqueue(Data("AFTER-THE-BARRIER".utf8))
        drainFully(coordinator, main)

        let text = core.getPlainText(startRow: 0, maxRows: 10)
        XCTAssertTrue(text.contains("RESTORED"), "the restored screen is the engine's state")
        XCTAssertFalse(text.contains("BEFORE-THE-BARRIER"), "pre-barrier bytes were replaced")
        XCTAssertTrue(text.contains("AFTER-THE-BARRIER"), "post-barrier bytes reached the new engine")
        XCTAssertEqual(restore.cols, 40)
        XCTAssertEqual(restore.rows, 10)
        XCTAssertEqual(restore.version, core.checkpointVersion())
        XCTAssertEqual(coordinator.checkpointImportCount, 1)
        XCTAssertEqual(recorder.restoreCount, 1)
        XCTAssertEqual(coordinator.mainThreadBatchCount, 0, "still never parsed on Main")
    }

    /// A barrier queued behind a burst is reached, not starved: `runParsePass`
    /// loops until the pending queue empties, and the import is *in* that
    /// queue rather than racing it from a separate block.
    func testCheckpointImportIsNotStarvedByAContinuingBurst() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        for i in 0..<200 {
            coordinator.enqueue(Data("burst \(i)\r\n".utf8))
        }
        let blob = checkpoint(of: "AFTER-BURST")
        let restore = try coordinator.importCheckpoint(blob)
        drainFully(coordinator, main)

        XCTAssertEqual(restore.cols, 40)
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 10).contains("AFTER-BURST"))
        XCTAssertEqual(coordinator.pendingWorkCount, 0, "the queue drained; nothing was starved")
        XCTAssertGreaterThan(coordinator.batchCount, 0, "the burst really was parsed first")
    }

    /// Several imports in a row each land, in order, each publishing a new
    /// engine generation.
    func testMultipleConsecutiveCheckpointImports() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        var epochs: [UInt64] = [core.stateEpoch()]
        let sizes: [(UInt32, UInt32)] = [(40, 10), (60, 12), (24, 8)]
        for (index, size) in sizes.enumerated() {
            let blob = checkpoint(of: "STATE-\(index)", cols: size.0, rows: size.1)
            let restore = try coordinator.importCheckpoint(blob)
            XCTAssertEqual(restore.cols, Int(size.0))
            XCTAssertEqual(restore.rows, Int(size.1))
            XCTAssertEqual(restore.epoch, core.stateEpoch())
            epochs.append(restore.epoch)
            coordinator.enqueue(Data("+\(index)".utf8))
        }
        drainFully(coordinator, main)

        XCTAssertEqual(epochs, epochs.sorted(), "each swap publishes a newer epoch")
        XCTAssertEqual(Set(epochs).count, epochs.count, "and never repeats one")
        XCTAssertEqual(coordinator.checkpointImportCount, 3)
        XCTAssertEqual(recorder.restoreCount, 3)
        XCTAssertEqual(core.cols(), 24)
        XCTAssertEqual(core.rows(), 8)
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 8).contains("STATE-2"))
    }

    /// A refused import changes nothing -- not the screen, not the epoch, not
    /// the coordinator -- and the next honest one still lands.
    func testFailedThenSuccessfulCheckpointImport() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.feedSynchronously(Data("ORIGINAL".utf8))
        let textBefore = core.bufferText()
        let stateBefore = core.checkpoint()
        let epochBefore = core.stateEpoch()

        for bad in [Data(), Data([1, 2, 3, 4, 5]), Data(repeating: 0xAA, count: 128)] {
            XCTAssertThrowsError(try coordinator.importCheckpoint(bad))
            XCTAssertEqual(core.bufferText(), textBefore, "fail-intact: the screen is untouched")
            XCTAssertEqual(core.checkpoint(), stateBefore, "fail-intact: byte-identical export")
            XCTAssertEqual(core.stateEpoch(), epochBefore, "a refusal publishes no epoch")
        }
        XCTAssertEqual(coordinator.checkpointImportFailureCount, 3)
        XCTAssertEqual(coordinator.checkpointImportCount, 0)
        XCTAssertEqual(recorder.restoreCount, 0)

        let restore = try coordinator.importCheckpoint(checkpoint(of: "RECOVERED"))
        drainFully(coordinator, main)
        XCTAssertGreaterThan(restore.epoch, epochBefore)
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 10).contains("RECOVERED"))
        XCTAssertEqual(recorder.restoreCount, 1)
    }

    /// Feeds and resizes running on other threads across an import: the import
    /// still lands exactly once, the engine ends on the restored generation,
    /// and nothing deadlocks.
    func testConcurrentFeedAndResizeAcrossACheckpointImport() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        let started = DispatchSemaphore(value: 0)
        let stop = DispatchSemaphore(value: 0)
        let feeder = DispatchQueue(label: "test.feeder")
        let resizer = DispatchQueue(label: "test.resizer")
        let finished = expectation(description: "background work finished")
        finished.expectedFulfillmentCount = 2

        feeder.async {
            started.signal()
            for i in 0..<400 {
                coordinator.enqueue(Data("concurrent \(i)\r\n".utf8))
            }
            finished.fulfill()
        }
        resizer.async {
            for i in 0..<200 {
                core.resize(cols: UInt32(40 + (i % 20)), rows: 10)
            }
            stop.signal()
            finished.fulfill()
        }
        started.wait()

        let restore = try coordinator.importCheckpoint(checkpoint(of: "SURVIVOR", cols: 33, rows: 9))
        stop.wait()
        waitForExpectations(timeout: 30)
        drainFully(coordinator, main)

        XCTAssertEqual(coordinator.checkpointImportCount, 1, "exactly one swap")
        XCTAssertEqual(recorder.restoreCount, 1)
        XCTAssertEqual(restore.cols, 33)
        XCTAssertEqual(restore.rows, 9)
        XCTAssertGreaterThanOrEqual(core.stateEpoch(), restore.epoch)
        XCTAssertEqual(coordinator.mainThreadBatchCount, 0)
        XCTAssertLessThanOrEqual(main.peakDepth, 1, "still at most one application outstanding")
    }

    /// A coordinator torn down while a barrier is still queued fails that
    /// barrier instead of leaving its caller parked on a semaphore forever.
    ///
    /// The interleaving is pinned rather than raced for: the injected main
    /// dispatch parks the parser queue *inside* a parse pass, so the barrier
    /// is provably still in the queue when `shutDown` runs.
    func testShutDownDuringACheckpointImportDoesNotHang() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)

        let parserParked = DispatchSemaphore(value: 0)
        let releaseParser = DispatchSemaphore(value: 0)
        let parkOnce = NSLock()
        var parked = false
        let coordinator = TerminalParserCoordinator(core: core) { block in
            parkOnce.lock()
            let shouldPark = !parked
            parked = true
            parkOnce.unlock()
            if shouldPark {
                // Runs on the parser queue, from inside the parse pass: the
                // pass cannot dequeue anything else until this returns.
                parserParked.signal()
                releaseParser.wait()
            }
            main.dispatch(block)
        }
        coordinator.setMainApplicationHandler(recorder.record)
        coordinator.setCheckpointRestoreHandler(recorder.recordRestore)

        coordinator.enqueue(Data("park the parser\r\n".utf8))
        XCTAssertEqual(parserParked.wait(timeout: .now() + 30), .success)

        let blob = checkpoint(of: "NEVER-APPLIED")
        let returned = expectation(description: "the import returned")
        let thrownLock = NSLock()
        var thrown: Error?
        DispatchQueue(label: "test.importer").async {
            do {
                _ = try coordinator.importCheckpoint(blob)
            } catch {
                thrownLock.lock()
                thrown = error
                thrownLock.unlock()
            }
            returned.fulfill()
        }

        // The barrier is queued behind a parser that cannot reach it.
        let deadline = Date().addingTimeInterval(30)
        while coordinator.pendingWorkCount == 0, Date() < deadline {
            usleep(1000)
        }
        XCTAssertEqual(coordinator.pendingWorkCount, 1, "the barrier is waiting in the queue")

        coordinator.shutDown()
        waitForExpectations(timeout: 30)
        releaseParser.signal()

        thrownLock.lock()
        let error = thrown
        thrownLock.unlock()
        XCTAssertEqual(
            error as? TerminalCheckpointImportError,
            .shutDown,
            "a barrier abandoned by shutdown fails as shutdown rather than hanging"
        )
        XCTAssertEqual(coordinator.checkpointImportCount, 0, "and never replaced the engine")

        // The engine outlives the coordinator: shutdown stops work reaching
        // the host, not the core.
        coordinator.waitForParserQuiescence()
        core.feed(bytes: Data("still alive".utf8))
        XCTAssertTrue(core.bufferText().contains("still alive"))

        // And an import attempted after shutdown fails immediately.
        XCTAssertThrowsError(try coordinator.importCheckpoint(blob)) { error in
            XCTAssertEqual(error as? TerminalCheckpointImportError, .shutDown)
        }
    }

    /// An outcome parsed before the swap is dropped rather than applied to the
    /// engine that replaced it.
    func testStaleOutcomesAreSuppressedByTheCheckpointEpoch() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        // Parsed, and deliberately NOT applied: the application is sitting on
        // the stand-in main queue.
        coordinator.enqueue(Data("\u{001B}]0;stale-title\u{0007}".utf8))
        coordinator.waitForParserQuiescence()
        XCTAssertEqual(recorder.outcomes.count, 0, "nothing applied yet")

        let restore = try coordinator.importCheckpoint(checkpoint(of: "FRESH"))
        drainFully(coordinator, main)

        XCTAssertEqual(coordinator.suppressedOutcomeCount, 1, "the pre-swap outcome was dropped")
        XCTAssertEqual(recorder.titles, [], "and never reached the host")
        XCTAssertEqual(recorder.restoreCount, 1)
        XCTAssertEqual(restore.epoch, core.stateEpoch())

        // A post-swap outcome under the current epoch is applied normally.
        coordinator.enqueue(Data("\u{001B}]0;live-title\u{0007}".utf8))
        drainFully(coordinator, main)
        XCTAssertEqual(recorder.titles, ["live-title"])
    }

    /// The epoch is validated where the outcome is *applied*, not only where
    /// it is published: an engine replaced between capture and application --
    /// here by `reset`, which swaps the engine on Main outside the coordinator
    /// entirely -- still invalidates it.
    func testStaleOutcomeIsSuppressedAtApplicationTime() {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.enqueue(Data("\u{001B}]0;doomed\u{0007}".utf8))
        coordinator.waitForParserQuiescence()

        // The engine is replaced on Main, behind the coordinator's back --
        // exactly the shape a coordinator-level epoch could not see.
        core.reset()

        main.drain()
        XCTAssertEqual(recorder.titles, [], "an outcome from the old engine is not applied")
        XCTAssertEqual(coordinator.suppressedOutcomeCount, 1)
        XCTAssertEqual(coordinator.appliedOutcomeCount, 0)
    }

    /// Interleaved feeds and imports all complete, with bounded work
    /// outstanding throughout: no batch dropped, none applied twice, at most
    /// one main application in flight.
    func testBoundedProgressUnderInterleavedFeedsAndImports() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        for round in 0..<12 {
            for chunk in 0..<8 {
                coordinator.enqueue(Data("round \(round) chunk \(chunk)\r\n".utf8))
            }
            _ = try coordinator.importCheckpoint(checkpoint(of: "ROUND-\(round)"))
            coordinator.enqueue(Data("\u{001B}]0;after-\(round)\u{0007}".utf8))
            drainFully(coordinator, main)
        }

        XCTAssertEqual(coordinator.checkpointImportCount, 12)
        XCTAssertEqual(recorder.restoreCount, 12)
        XCTAssertEqual(coordinator.pendingWorkCount, 0)
        XCTAssertEqual(
            coordinator.appliedOutcomeCount + coordinator.suppressedOutcomeCount,
            coordinator.batchCount,
            "every parsed batch was either applied or explicitly suppressed"
        )
        XCTAssertEqual(coordinator.peakOutstandingMainApplications, 1)
        XCTAssertLessThanOrEqual(main.peakDepth, 1)
        XCTAssertEqual(recorder.titles, (0..<12).map { "after-\($0)" })
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 10).contains("ROUND-11"))
    }

    /// A restore is not a reset. `reset()` feeds `ESC c` -- a byte stream the
    /// terminal interprets; an import hands the engine a whole state. The
    /// import parses no bytes at all, and the restored content survives, which
    /// an `ESC c` would have cleared.
    func testCheckpointRestoreIsNotExpressedAsAReset() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.feedSynchronously(Data("SCRATCH".utf8))
        let batchesBefore = coordinator.batchCount

        let restore = try coordinator.importCheckpoint(checkpoint(of: "KEEP-ME\u{001B}]0;kept\u{0007}"))
        drainFully(coordinator, main)

        XCTAssertEqual(coordinator.batchCount, batchesBefore, "no bytes were fed to express the import")
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 10).contains("KEEP-ME"))
        XCTAssertEqual(core.title(), "kept", "restored state, not a cleared terminal")
        XCTAssertEqual(restore.cols, 40)
    }

    /// The engine adopts the checkpoint's own geometry, and the coordinator
    /// reports it rather than turning it into a resize request.
    func testCheckpointRestoreReportsGeometryWithoutReflowing() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 80, rows: 24)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        let blob = checkpoint(of: "NARROW", cols: 33, rows: 7)
        let restore = try coordinator.importCheckpoint(blob)
        drainFully(coordinator, main)

        XCTAssertEqual(restore.cols, 33)
        XCTAssertEqual(restore.rows, 7)
        XCTAssertEqual(core.cols(), 33, "the canonical grid is not reflowed to the view's size")
        XCTAssertEqual(core.rows(), 7)
        XCTAssertEqual(recorder.restores.map { [$0.cols, $0.rows] }, [[33, 7]])
    }
}
