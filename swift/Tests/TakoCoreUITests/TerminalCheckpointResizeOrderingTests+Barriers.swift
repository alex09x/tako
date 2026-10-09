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

extension TerminalCheckpointResizeOrderingTests {
    func testResizeCompletesAtItsBarrierWhileLaterInputIsStillOutstanding() {
        let main = GatedMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)
        coordinator.setMainApplicationHandler(recorder.record)
        coordinator.setCheckpointRestoreHandler(recorder.recordRestore)
        coordinator.setResizeHandler(recorder.recordResize)

        // One batch, then the parser hops to Main and parks there -- holding
        // the parser queue, which is the point.
        coordinator.enqueue(title("before"))
        waitUntil("the parser to reach the gate") { main.arrivalCount >= 1 }
        XCTAssertEqual(coordinator.pendingWorkCount, 0, "the first batch should be taken")

        let returned = expectation(description: "resize returned")
        DispatchQueue.global().async {
            coordinator.resize(cols: 20, rows: 5)
            returned.fulfill()
        }
        waitUntil("the resize to take its place in the queue") {
            coordinator.pendingWorkCount >= 1
        }

        // Input that arrives after the barrier. It belongs to the new
        // geometry and the resize has no business waiting for it.
        coordinator.enqueue(title("after"))
        waitUntil("the later bytes to be queued behind the barrier") {
            coordinator.pendingWorkCount >= 2
        }

        // Let the parser past the first hop only. It now reaches the resize
        // barrier -- and parks again at the next hop, with the later bytes
        // still sitting in the queue.
        main.letOneThrough()

        wait(for: [returned], timeout: 5)

        XCTAssertEqual(coordinator.appliedResizeCount, 1, "the barrier ran exactly once")
        XCTAssertEqual(recorder.appliedGeometries.count, 1, "and was reported exactly once")
        XCTAssertEqual(recorder.appliedGeometries.first?.cols, 20)
        XCTAssertEqual(recorder.appliedGeometries.first?.rows, 5)
        XCTAssertGreaterThan(
            coordinator.pendingWorkCount, 0,
            "the resize waited for input that arrived after it"
        )
        XCTAssertEqual(Int(core.cols()), 20, "the engine holds the new geometry")
        XCTAssertEqual(Int(core.rows()), 5)

        coordinator.shutDown()
        main.release(8)
    }

    /// A barrier's *publication* must be bounded too, not just its wait.
    ///
    /// Completing at the barrier fixed when the caller stops waiting. It did
    /// not bound what the caller does next: the apply loop takes whatever is
    /// in the queue, and a producer that keeps supplying outcomes while Main
    /// is applying earlier ones keeps that loop fed. The caller's own resize
    /// was published in the first pass and it is still on Main.
    ///
    /// This is the shape that does it, and it is not a timing race: the
    /// producer lives *inside* the application handlers, so every new outcome
    /// is already parsed and queued before the handler that produced it
    /// returns. The loop can never observe an empty queue.
    ///
    /// The bound is the caller's own barrier. Everything the producer supplies
    /// after it still has to be applied -- in order, exactly once -- just not
    /// on the resizing caller's clock.
    func testResizeReturnsWithoutApplyingOutcomesProducedAfterItsBarrier() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)

        // A producer that injects the next write from inside whatever handler
        // is running, and does not return until the parser has turned it into
        // an outcome waiting on the queue.
        let injections = Injector(coordinator: coordinator, limit: 10)

        coordinator.setMainApplicationHandler { outcomes in
            recorder.record(outcomes)
            injections.recordApplication(count: outcomes.count)
            injections.injectNext()
        }
        coordinator.setResizeHandler { cols, rows in
            recorder.recordResize(cols: cols, rows: rows)
            injections.barrierPublished()
            injections.injectNext()
        }

        coordinator.enqueue(title("before"))
        coordinator.resize(cols: 20, rows: 5)

        // The claim: the resize returned having published its own barrier and
        // nothing the producer supplied afterwards.
        XCTAssertEqual(
            injections.applicationsAfterBarrier, 0,
            "the resize applied \(injections.applicationsAfterBarrier) outcomes produced " +
            "after its own barrier before returning -- its publication is unbounded"
        )
        XCTAssertEqual(coordinator.appliedResizeCount, 1)
        XCTAssertEqual(recorder.appliedGeometries.count, 1, "and published it exactly once")

        // Nothing was dropped to achieve that: the producer's writes are still
        // owed, and draining Main delivers every one of them, in order and
        // exactly once, after the barrier.
        drainFully(coordinator, main)
        XCTAssertEqual(
            recorder.events,
            ["title(before)", "resize(20x5)"] + (1...10).map { "title(after\($0))" }
        )
        XCTAssertEqual(coordinator.suppressedOutcomeCount, 0)

        coordinator.shutDown()
    }

    /// Import publishes through the same loop and needs the same bound. Same
    /// producer, same claim.
    func testImportReturnsWithoutApplyingOutcomesProducedAfterItsBarrier() throws {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)

        let source = TakoCore(cols: 30, rows: 8)
        source.feed(bytes: Data("RESTORED".utf8))
        let blob = source.checkpoint()

        let injections = Injector(coordinator: coordinator, limit: 10)

        coordinator.setMainApplicationHandler { outcomes in
            recorder.record(outcomes)
            injections.recordApplication(count: outcomes.count)
            injections.injectNext()
        }
        coordinator.setCheckpointRestoreHandler { restore in
            recorder.recordRestore(restore)
            injections.barrierPublished()
            injections.injectNext()
        }

        let restore = try coordinator.importCheckpoint(blob)
        XCTAssertEqual(restore.cols, 30)

        XCTAssertEqual(
            injections.applicationsAfterBarrier, 0,
            "the import applied \(injections.applicationsAfterBarrier) outcomes produced " +
            "after its own barrier before returning -- its publication is unbounded"
        )

        drainFully(coordinator, main)
        XCTAssertEqual(
            recorder.events,
            ["restore(30x8)"] + (1...10).map { "title(after\($0))" }
        )

        coordinator.shutDown()
    }

    /// A refused import is a barrier too, and it has to be published.
    ///
    /// The successful path marks the request published the instant its
    /// restore reaches the host, which is what stops the importing caller
    /// from carrying somebody else's work. A refused import has nothing to
    /// hand the host -- the engine is exactly what it was -- and so nothing
    /// marked it, leaving the caller waiting on a barrier that could never
    /// arrive. It then drains whatever the parser keeps producing, on Main,
    /// for as long as the producer keeps producing.
    ///
    /// The bound has to come from the queue, not from the publication: the
    /// rejection takes its place in the same FIFO and is published there,
    /// delivering nothing.
    func testRefusedImportReturnsWithoutApplyingOutcomesProducedAfterItsBarrier() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)
        coordinator.setCheckpointRestoreHandler(recorder.recordRestore)
        coordinator.setResizeHandler(recorder.recordResize)

        let injections = Injector(coordinator: coordinator, limit: 10)
        coordinator.setMainApplicationHandler { outcomes in
            recorder.record(outcomes)
            injections.recordApplication(count: outcomes.count)
            injections.injectNext()
            // Nothing publishes a rejection to the host, so the barrier is
            // marked here instead: the injection above is queued behind the
            // refused import, so everything applied from now on is work the
            // caller produced after its own barrier.
            injections.barrierPublished()
        }

        // One outcome waiting ahead of the barrier, so the handler runs once
        // and the producer starts. Its application stays queued: this Main
        // runs nothing until the test drains it.
        coordinator.enqueue(title("seed"))
        coordinator.waitForParserQuiescence()

        XCTAssertThrowsError(try coordinator.importCheckpoint(Data([1, 2, 3]))) { error in
            XCTAssertFalse(
                error is TerminalCheckpointImportError,
                "the engine's own refusal should surface, not a coordinator error: \(error)"
            )
        }

        XCTAssertEqual(
            injections.applicationsAfterBarrier, 0,
            "the refused import applied \(injections.applicationsAfterBarrier) outcomes " +
            "produced after its own barrier before returning -- its barrier is never published"
        )

        // Nothing was restored and nothing was resized: a refusal publishes
        // no state change, only its own place in the order.
        XCTAssertEqual(coordinator.checkpointImportCount, 0)
        XCTAssertEqual(coordinator.checkpointImportFailureCount, 1)
        XCTAssertEqual(coordinator.suppressedOutcomeCount, 0)

        drainFully(coordinator, main)
        XCTAssertEqual(
            recorder.events,
            ["title(seed)"] + (1...10).map { "title(after\($0))" },
            "every outcome must still be delivered exactly once, in order"
        )
        XCTAssertEqual(coordinator.peakOutstandingMainApplications, 1)

        coordinator.shutDown()
    }
}

/// Supplies the next write from inside whichever handler is running, and
/// blocks until the parser has produced its outcome -- so the apply loop is
/// never looking at an empty queue when it decides whether to keep going.
///
/// Bounded on purpose: an unbounded producer would hang a build with the
/// defect instead of failing it.
final class Injector: @unchecked Sendable {
    private let coordinator: TerminalParserCoordinator
    private let limit: Int
    private let lock = NSLock()
    private var issued = 0
    private var published = false
    private var appliedAfterBarrier = 0

    init(coordinator: TerminalParserCoordinator, limit: Int) {
        self.coordinator = coordinator
        self.limit = limit
    }

    func barrierPublished() { lock.withLock { published = true } }

    func recordApplication(count: Int) {
        lock.lock()
        if published { appliedAfterBarrier += count }
        lock.unlock()
    }

    func injectNext() {
        lock.lock()
        guard issued < limit else { lock.unlock(); return }
        issued += 1
        let index = issued
        lock.unlock()
        coordinator.enqueue(Data("\u{1B}]0;after\(index)\u{07}".utf8))
        // Parser-only: this never waits on Main, so it cannot deadlock the
        // handler it is called from. When it returns the outcome is queued.
        coordinator.waitForParserQuiescence()
    }

    var applicationsAfterBarrier: Int { lock.withLock { appliedAfterBarrier } }
}
