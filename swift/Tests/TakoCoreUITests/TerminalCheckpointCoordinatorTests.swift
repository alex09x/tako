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
import XCTest
@testable import TakoCoreUI

/// A stand-in for the main queue: an application lands here instead of being
/// dispatched, so a test decides exactly when it runs.
final class CheckpointMainQueue: @unchecked Sendable {
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
final class CheckpointRecorder: @unchecked Sendable {
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

}
